module Quasar.Network.Multiplexer (
  -- * Channel type
  RawChannel(quasar),

  -- * Sending and receiving messages
  MessageId,

  -- ** Sending messages
  SendMessageContext(..),
  addDataMessagePart,
  addChannelMessagePart,
  AbortSend(..),
  sendRawChannelMessage,
  sendRawChannelMessageDeferred,
  sendRawChannelMessageDeferred_,
  unsafeQueueRawChannelMessage,

  -- ** Receiving messages
  ReceiveMessageContext(..),
  acceptDataMessagePart,
  acceptChannelMessagePart,
  RawChannelHandler,
  rawChannelSetHandler,
  binaryHandler,
  simpleBinaryHandler,
  simpleByteStringHandler,
  rawChannelSetSimpleByteStringHandler,

  -- ** Exception handling
  MultiplexerException(..),
  MultiplexerDirection(..),
  ConnectionLostReason(..),
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,
  ParseException(..),

  -- * Create or run a multiplexer
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Monad.Catch
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.State qualified as State
import Control.Monad.Trans (lift)
import Data.Binary (Binary, decodeOrFail)
import Data.Binary qualified as Binary
import Data.Binary.Get (Decoder(..), runGetIncremental, pushChunk)
import Data.Binary.Put qualified as Binary
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import Quasar
import Quasar.Exceptions
import Quasar.Network.Connection
import Quasar.Prelude
import System.Timeout (timeout)

-- * Types

-- | Designed for long-running processes
type ChannelId = Word64
type MessageId = Word64

-- ** Wire format

magicBytes :: BS.ByteString
magicBytes = "qso\0dev\0"

-- | Low level network protocol control message
data MultiplexerMessage
  = ChannelMessage ChannelId BSL.ByteString [MessagePart]
  | CloseChannel ChannelId
  | ChannelProtocolError ChannelId String
  | MultiplexerProtocolError String
  | InternalError String
  deriving stock (Generic, Show)

instance Binary MultiplexerMessage

data MessagePart
  = ChannelMessagePart BSL.ByteString [MessagePart]
  | DataMessagePart BSL.ByteString
  deriving stock (Generic, Show)

instance Binary MessagePart



-- ** Multiplexer

data OutboxMessage
  = OutboxSendMessage RawChannel (SendMessageContext -> STMc NoRetry '[] (Maybe BSL.ByteString))
  | OutboxCloseChannel RawChannel

data Multiplexer = Multiplexer {
  side :: MultiplexerSide,
  disposer :: Disposer,
  multiplexerException :: Promise MultiplexerException,
  multiplexerResult :: Promise (Maybe MultiplexerException),
  receiveThreadCompleted :: Future (),
  -- Set to true after magic bytes have been received
  receivedHeader :: TVar Bool,
  outbox :: TVar [OutboxMessage],
  outboxGuard :: MVar (),
  channelsVar :: TVar (HM.HashMap ChannelId RawChannel),
  nextReceiveChannelId :: TVar ChannelId,
  nextSendChannelId :: TVar ChannelId
}
instance Disposable Multiplexer where
  getDisposer multiplexer = multiplexer.disposer

-- | 'MultiplexerSideA' describes the initiator of a connection, i.e. the client in most cases.
--
-- Side A will send multiplexer headers before the server sends a response.
--
-- In cases where there is no clear initiator or client/server relation, the side which usually sends the first message
-- should be side A.
data MultiplexerSide = MultiplexerSideA | MultiplexerSideB
  deriving stock (Eq, Show)

data MultiplexerException
  = ConnectionLost ConnectionLostReason
  | InvalidMagicBytes BS.ByteString
  | LocalException MultiplexerDirection SomeException
  | RemoteException String
  | ProtocolException String
  | ReceivedProtocolException String
  | ChannelProtocolException ChannelId String
  | ReceivedChannelProtocolException ChannelId String
  deriving stock Show

instance Exception MultiplexerException where
  displayException (InvalidMagicBytes received) =
    mconcat ["Magic bytes don't match: Expected ", show magicBytes, ", got ", show received]
  displayException (LocalException direction inner) =
    mconcat ["Multiplexer failed due to a local exception (", show direction, "):\n", displayException inner]
  displayException ex = show ex

data MultiplexerDirection = Sending | Receiving
  deriving stock Show

data ConnectionLostReason
  = SendFailed SomeException
  | ReceiveFailed SomeException
  | CloseTimeoutReached -- "Multiplexer reached timeout while closing connection"
  deriving stock Show

instance Exception ConnectionLostReason where
  displayException (SendFailed ex) = displayException ex
  displayException (ReceiveFailed ex) = "Failed to send: " <> displayException ex
  displayException CloseTimeoutReached = "Multiplexer reached timeout while closing connection"

protocolException :: MonadThrow m => String -> m a
protocolException = throwM . ProtocolException

newtype ParseException = ParseException String
  deriving stock Show

instance Exception ParseException

-- ** Channel

data RawChannel = RawChannel {
  multiplexer :: Multiplexer,
  quasar :: Quasar,
  channelId :: ChannelId,
  channelHandler :: TVar (Maybe RawChannelHandler),
  parent :: Maybe RawChannel,
  children :: TVar (HM.HashMap ChannelId RawChannel),
  receivedCloseMessage :: TVar Bool,
  sentCloseMessage :: TVar Bool
}

instance Disposable RawChannel where
  getDisposer channel = getDisposer channel.quasar

newRootChannel :: Multiplexer -> QuasarIO RawChannel
newRootChannel multiplexer = do
  quasar <- askQuasar
  channel <- liftIO do
    channelHandler <- newTVarIO Nothing
    children <- newTVarIO mempty
    receivedCloseMessage <- newTVarIO False
    sentCloseMessage <- newTVarIO False

    pure RawChannel {
      multiplexer,
      quasar,
      channelId = 0,
      channelHandler,
      parent = Nothing,
      children,
      receivedCloseMessage,
      sentCloseMessage
    }

  registerSimpleDisposeTransactionIO_ $ sendChannelCloseMessage channel

  pure channel

newChannel :: RawChannel -> ChannelId -> STMc NoRetry '[] RawChannel
newChannel parent@RawChannel{multiplexer, quasar=parentQuasar} channelId = do
  -- Channels inherit their parents close state
  parentReceivedCloseMessage <- readTVar parent.receivedCloseMessage
  parentSentCloseMessage <- readTVar parent.sentCloseMessage

  quasar <- newOrClosedResourceScopeSTM parentQuasar
  channelHandler <- newTVar Nothing
  children <- newTVar mempty
  receivedCloseMessage <- newTVar parentReceivedCloseMessage
  sentCloseMessage <- newTVar parentSentCloseMessage

  let channel = RawChannel {
    multiplexer,
    quasar,
    channelId,
    channelHandler,
    parent = Just parent,
    children,
    receivedCloseMessage,
    sentCloseMessage
  }

  -- Attach to parent
  modifyTVar parent.children $ HM.insert channelId channel

  disposer <- newUnmanagedTSimpleDisposer (sendChannelCloseMessage channel)
  tryAttachResource quasar.resourceManager disposer >>= \case
    Right () -> pure ()
    Left FailedToAttachResource -> disposeTSimpleDisposer disposer

  modifyTVar multiplexer.channelsVar $ HM.insert channelId channel

  pure channel

sendChannelCloseMessage :: RawChannel -> STMc NoRetry '[] ()
sendChannelCloseMessage channel = do
  alreadySent <- readTVar channel.sentCloseMessage
  unless alreadySent do
    modifyTVar channel.multiplexer.outbox (OutboxCloseChannel channel :)
    -- Mark as closed and propagate close state to children
    markAsClosed channel
    cleanupChannel channel
  where
    markAsClosed :: RawChannel -> STMc NoRetry '[] ()
    markAsClosed markChannel = do
      writeTVar markChannel.sentCloseMessage True
      children <- readTVar markChannel.children
      mapM_ markAsClosed children

setReceivedChannelCloseMessage :: RawChannel -> STMc NoRetry '[] ()
setReceivedChannelCloseMessage channel = do
  writeTVar channel.receivedCloseMessage True
  children <- readTVar channel.children
  mapM_ setReceivedChannelCloseMessage children
  cleanupChannel channel

cleanupChannel :: RawChannel -> STMc NoRetry '[] ()
cleanupChannel channel = do
  whenM (readTVar channel.sentCloseMessage) do
    whenM (readTVar channel.receivedCloseMessage) do
      -- Deregister from multiplexer
      modifyTVar channel.multiplexer.channelsVar $ HM.delete channel.channelId

      -- Deregister from parent
      case channel.parent of
        Just parent -> modifyTVar parent.children $ HM.delete channel.channelId
        Nothing -> pure ()

      -- Children are closed implicitly, so they have to be cleaned up as well
      mapM_ cleanupChannel =<< readTVar channel.children

verifyChannelIsConnected :: RawChannel -> STMc NoRetry '[ChannelException] ()
verifyChannelIsConnected channel = do
  whenM (readTVar channel.sentCloseMessage) $ throwC ChannelNotConnected
  whenM (readTVar channel.receivedCloseMessage) $ throwC ChannelNotConnected

data ChannelException = ChannelNotConnected
  deriving stock Show

instance Exception ChannelException


-- ** Channel message interface

type RawChannelHandler = ReceiveMessageContext -> BSL.ByteString -> QuasarIO ()

runRawChannelHandler :: RawChannelHandler -> ReceiveMessageContext -> BSL.ByteString -> IO ()
runRawChannelHandler handler context message = do
  -- When the channel/multiplexer is currently closing, running the
  -- callback might no longer be possible.
  handle (\FailedToAttachResource -> pure ()) do
    execForeignQuasarIO context.channel.quasar do
      handler context message

newtype SendMessageContext = SendMessageContext {
  addMessagePart ::
    Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler)) ->
    STMc NoRetry '[] ()
}

addDataMessagePart :: SendMessageContext -> BSL.ByteString -> STMc NoRetry '[] ()
addDataMessagePart context blob = addMessagePart context (Left blob)

addChannelMessagePart :: SendMessageContext -> (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler)) -> STMc NoRetry '[] ()
addChannelMessagePart context initChannelFn = addMessagePart context (Right initChannelFn)

data ReceiveMessageContext = ReceiveMessageContext {
  channel :: RawChannel,
  -- TODO rename
  numCreatedChannels :: Int,
  -- Must be called exactly once for every sent channel.
  acceptMessagePart :: forall a.
    (
      BSL.ByteString ->
      Either ParseException (Either a (
        RawChannel ->
        ReceiveMessageContext ->
        STMc NoRetry '[MultiplexerException] (RawChannelHandler, a)
      ))
    ) ->
    STMc NoRetry '[MultiplexerException] a
  --unixFds :: Undefined
}

data ReceivedMessagePart
  = ReceivedChannelMessagePart RawChannel BSL.ByteString [ReceivedMessagePart]
  | ReceivedDataMessagePart BSL.ByteString
  deriving stock (Generic)

acceptDataMessagePart :: forall a.
  ReceiveMessageContext ->
  (BSL.ByteString -> Either ParseException a) ->
  STMc NoRetry '[MultiplexerException] a
acceptDataMessagePart context parseFn =
  acceptMessagePart context \cdata -> Left <$> parseFn cdata

acceptChannelMessagePart :: forall a.
  ReceiveMessageContext ->
  (
    BSL.ByteString ->
    Either ParseException (
      RawChannel ->
      ReceiveMessageContext ->
      STMc NoRetry '[MultiplexerException] (RawChannelHandler, a)
    )
  ) ->
  STMc NoRetry '[MultiplexerException] a
acceptChannelMessagePart context fn =
  acceptMessagePart context \cdata -> Right <$> fn cdata


-- * Implementation

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling `dispose`; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> (RawChannel -> QuasarIO ()) -> Connection -> m ()
runMultiplexer side channelSetupHook connection = liftQuasarIO $ mask_ do
  (rootChannel, result) <- newMultiplexerInternal side connection
  runQuasarIO rootChannel.quasar $ channelSetupHook rootChannel
  mException <- await result
  mapM_ throwM mException

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> Connection -> m RawChannel
newMultiplexer side connection = liftQuasarIO $ mask_ do
  exceptionSink <- askExceptionSink
  (rootChannel, result) <- newMultiplexerInternal side connection
  -- TODO review the uninterruptibleMask (currently ensures the exception is delivered - can be improved by properly using the ExceptionSink now)
  async_ $ liftIO $ uninterruptibleMask_ do
    mException <- await result
    mapM_ (atomically . throwToExceptionSink exceptionSink) mException
  pure rootChannel

newMultiplexerInternal :: MultiplexerSide -> Connection -> QuasarIO (RawChannel, Future (Maybe MultiplexerException))
newMultiplexerInternal side connection = disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by
  -- `disposeOnError`, so it can be used as a disposable without accidentally
  -- disposing external resources.
  resourceManager <- askResourceManager

  outbox <- liftIO $ newTVarIO []
  multiplexerException <- newPromiseIO
  multiplexerResult <- newPromiseIO
  outboxGuard <- liftIO $ newMVar ()
  receivedHeader <- liftIO $ newTVarIO False
  nextReceiveChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 2 else 1
  nextSendChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 1 else 2

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    multiplexer <- mfix \multiplexer -> do
      sendingExSink <- catchSink (multiplexerExceptionHandler multiplexer Sending) <$> askExceptionSink
      receivingExSink <- catchSink (multiplexerExceptionHandler multiplexer Receiving) <$> askExceptionSink

      receiveTask <- unmanagedAsync receivingExSink $
        receiveThread multiplexer (receiveCheckEOF connection)
      sendTask <- unmanagedAsync sendingExSink $
        sendThread multiplexer connection.send

      let
        sendThreadCompleted = void $ toFuture sendTask
        receiveThreadCompleted = void $ toFuture receiveTask

      registerDisposeActionIO_ do
        -- NOTE The network connection should be closed automatically when the root channel is closed.
        -- This action exists to ensure the network connection is not blocking a resource manager for an unbounded
        -- amount of time while having enough time to perform a graceful close.

        -- Valid reasons to abort the multiplexer threads:
        r <- timeout 2000000 $ await
          -- Send *and* receive thread have terminated on their own, which happens after final messages (i.e. root
          -- channel closed or error messages) have been exchanged.
          (sendThreadCompleted >> receiveThreadCompleted)

        -- Timeout reached
        when (isNothing r) do
          fulfillPromiseIO multiplexerException $ ConnectionLost CloseTimeoutReached

        sf <- disposeEventuallyIO sendTask
        rf <- disposeEventuallyIO receiveTask
        await $ sf <> rf

        connection.close

        fulfillPromiseIO multiplexerResult =<< peekFutureIO (toFuture multiplexerException)

      pure Multiplexer {
        side,
        disposer = getDisposer resourceManager,
        multiplexerException,
        multiplexerResult,
        receiveThreadCompleted,
        outbox,
        outboxGuard,
        receivedHeader,
        channelsVar,
        nextReceiveChannelId,
        nextSendChannelId
      }

    newRootChannel multiplexer

  pure (rootChannel, toFuture multiplexerResult)


multiplexerExceptionHandler :: MonadSTMc NoRetry '[] m => Multiplexer -> MultiplexerDirection -> SomeException -> m ()
multiplexerExceptionHandler multiplexer direction (toMultiplexerException direction -> ex) = liftSTMc @NoRetry @'[] do
  unlessM (tryFulfillPromise multiplexer.multiplexerException ex) do
    queueLogError $ "Multiplexer ignored exception: " <> displayException ex <> "\nMultiplexer already failed with: " <> displayException ex
  disposeEventually_ multiplexer

toMultiplexerException :: MultiplexerDirection -> SomeException -> MultiplexerException
-- Exception is a MultiplexerException already
toMultiplexerException _ (fromException -> Just ex) = ex
-- Otherwise it's a local exception (usually from application code) (may be on a multiplexer thread)
toMultiplexerException direction (fromException -> Just (AsyncException ex)) =
  LocalException direction ex
toMultiplexerException direction ex = LocalException direction ex


sendThread :: Multiplexer -> (BSL.ByteString -> IO ()) -> IO ()
sendThread multiplexer sendFn = do
  case multiplexer.side of
    MultiplexerSideA -> sendRaw (BSL.fromStrict magicBytes)
    MultiplexerSideB -> do
      -- Block sending until magic bytes have been received
      atomically $ check =<< readTVar multiplexer.receivedHeader
  sendLoop
  where
    sendRaw :: BSL.ByteString -> IO ()
    sendRaw chunks = sendFn chunks `catchAll` (throwM . ConnectionLost . SendFailed)
    send :: [MultiplexerMessage] -> IO ()
    send msgs = sendRaw (Binary.runPut (foldMap Binary.put msgs))

    sendLoop :: IO ()
    sendLoop = do
      join $ atomically do
        peekFuture (toFuture multiplexer.multiplexerException) >>= \case
          -- Send exception (if required for that exception type) and then terminate send loop
          Just fatalException -> pure $ sendException fatalException
          Nothing -> do
            messages <- swapTVar multiplexer.outbox []
            case messages of
              -- Exit when the receive thread has stopped and there is no error and no message left to send
              [] -> pure () <$ readFuture multiplexer.receiveThreadCompleted
              _ -> pure do
                -- outbox is a list that is used as a queue, so it has to be reversed to preserve the correct order
                msgs <- mapM formatMessage (reverse messages)
                send (catMaybes msgs)
                sendLoop

    sendException :: MultiplexerException -> IO ()
    sendException (ConnectionLost _) = pure ()
    sendException (InvalidMagicBytes _) = pure ()
    sendException (LocalException _ ex) =
      send [InternalError $ displayException ex]
    sendException (RemoteException _) = pure ()
    sendException (ProtocolException message) =
      send [MultiplexerProtocolError message]
    sendException (ReceivedProtocolException _) = pure ()
    sendException (ChannelProtocolException channelId message) =
      send [ChannelProtocolError channelId message]
    sendException (ReceivedChannelProtocolException _ _) = pure ()

    formatMessage :: OutboxMessage -> IO (Maybe MultiplexerMessage)
    formatMessage (OutboxCloseChannel channel) = pure (Just (CloseChannel channel.channelId))
    formatMessage (OutboxSendMessage channel msgHook) = do
      atomicallyC do
        messageParts <- newTVar mempty
        msgHook (SendMessageContext (addMessagePart channel messageParts)) >>= \case
          Just message -> do
            -- List is used as a queue, so it needs to be reversed
            parts <- reverse <$> readTVar messageParts
            pure (Just (ChannelMessage channel.channelId message parts))
          Nothing -> pure Nothing

    addMessagePart :: RawChannel -> TVar [MessagePart] -> Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler)) -> STMc NoRetry '[] ()
    addMessagePart _parentChannel var (Left cdata) = modifyTVar var (DataMessagePart cdata :)
    addMessagePart parentChannel var (Right fn) = do
      newChannelId <- createChannelId multiplexer.nextSendChannelId
      channel <- newChannel parentChannel newChannelId

      -- TODO deduplicate code from formatMessage
      messageParts <- newTVar mempty
      (cdata, handler) <- fn channel (SendMessageContext (addMessagePart channel messageParts))
      rawChannelSetHandler channel handler

      -- List is used as a queue, so it needs to be reversed
      parts <- reverse <$> readTVar messageParts

      modifyTVar var (ChannelMessagePart cdata parts :)



data ReceiveLoop = Continue | Exit

receiveThread :: Multiplexer -> IO BS.ByteString -> IO ()
receiveThread multiplexer readFn = do
  chunk <- case multiplexer.side of
    MultiplexerSideA -> readBytes
    MultiplexerSideB -> checkMagicBytes
  evalStateT multiplexerLoop chunk
  where
    readBytes :: IO BS.ByteString
    readBytes = readFn `catchAll` \ex -> throwM $ ConnectionLost $ ReceiveFailed ex

    -- Reads and verifies magic bytes. Returns bytes left over from the received chunk(s).
    checkMagicBytes :: IO BS.ByteString
    checkMagicBytes = checkMagicBytes' ""
      where
        magicBytesLength = BS.length magicBytes
        checkMagicBytes' :: BS.ByteString -> IO BS.ByteString
        checkMagicBytes' chunk@((< magicBytesLength) . BS.length -> True) = do
          next <- readBytes `catchAll` \_ -> throwM (InvalidMagicBytes chunk)
          checkMagicBytes' $ chunk <> next
        checkMagicBytes' (BS.splitAt magicBytesLength -> (bytes, leftovers)) = do
          when (bytes /= magicBytes) $ throwM $ InvalidMagicBytes bytes
          -- Confirm magic bytes
          atomically $ writeTVar multiplexer.receivedHeader True
          pure leftovers

    multiplexerLoop :: StateT BS.ByteString IO ()
    multiplexerLoop = do
      msg <- getMultiplexerMessage
      loop <- liftIO $ execReceivedMultiplexerMessage msg
      case loop of
        Continue -> multiplexerLoop
        Exit -> pure ()

    lookupChannel :: ChannelId -> IO (Maybe RawChannel)
    lookupChannel channelId = do
      HM.lookup channelId <$> readTVarIO multiplexer.channelsVar

    requireReceivingChannel :: ChannelId -> IO RawChannel
    requireReceivingChannel channelId = do
      lookupChannel channelId >>= \case
        Nothing -> protocolException $
          fold ["Received data for invalid channel id ", show channelId]
        Just channel -> do
          receivedClose <- readTVarIO channel.receivedCloseMessage
          when receivedClose $ protocolException $
            fold ["Received data for invalid channel id ", show channelId, " (channel was closed by remote)"]
          pure channel

    getMultiplexerMessage :: StateT BS.ByteString IO MultiplexerMessage
    getMultiplexerMessage = do
      stateStateM $ liftIO . stepDecoder . pushChunk (runGetIncremental Binary.get)
      where
        stepDecoder :: Decoder a -> IO (a, BS.ByteString)
        stepDecoder (Fail _ _ errMsg) = protocolException $ "Failed to parse protocol message: " <> errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< readBytes
        stepDecoder (Done leftovers _ msg) = pure (msg, leftovers)

    execReceivedMultiplexerMessage :: MultiplexerMessage -> IO ReceiveLoop
    execReceivedMultiplexerMessage (MultiplexerProtocolError msg) = throwM $ RemoteException $
      "Remote closed connection because of a multiplexer protocol error: " <> msg
    execReceivedMultiplexerMessage (ChannelProtocolError channelId msg) = do
      channel <- requireReceivingChannel channelId
      throwM $ ChannelProtocolException channel.channelId msg
    execReceivedMultiplexerMessage (InternalError msg) =
      throwM $ RemoteException msg

    execReceivedMultiplexerMessage (CloseChannel channelId) = liftIO do
      channel <- requireReceivingChannel channelId
      atomicallyC do
        setReceivedChannelCloseMessage channel
        sendChannelCloseMessage channel
      disposeEventuallyIO_ channel
      pure if channel.channelId /= 0
        then Continue
        -- Terminate receive thread
        else Exit

    execReceivedMultiplexerMessage (ChannelMessage channelId message parts) = do
      -- requireReceivingChannel checks for receivedCloseMessage
      channel <- requireReceivingChannel channelId

      receivedParts <- atomicallyC $ mapM (initializeMessagePart channel) parts
      receivedPartsVar <- newTVarIO receivedParts

      sentClose <- readTVarIO channel.sentCloseMessage

      -- Drop received messages when the channel has been closed on the local side
      unless sentClose do

        -- Blocks until a channel handler is set. Channels handlers are usually
        -- set during channel initialisation.
        messageHandler <- atomically $ maybe retry pure =<< readTVar channel.channelHandler

        let context = ReceiveMessageContext {
          channel,
          numCreatedChannels = length receivedParts,
          acceptMessagePart = acceptMessagePartCallback receivedPartsVar
        }
        runRawChannelHandler messageHandler context message

        unlessM (null <$> readTVarIO receivedPartsVar) do
          throwM $ ChannelProtocolException channel.channelId "Received message parts were not handled"

      pure Continue

    initializeMessagePart :: RawChannel -> MessagePart -> STMc NoRetry '[] ReceivedMessagePart
    initializeMessagePart _parentChannel (DataMessagePart cdata) = pure (ReceivedDataMessagePart cdata)
    initializeMessagePart parentChannel (ChannelMessagePart cdata parts) = do
      channelId <- createChannelId multiplexer.nextReceiveChannelId
      channel <- newChannel parentChannel channelId
      receivedParts <- mapM (initializeMessagePart channel) parts
      pure (ReceivedChannelMessagePart channel cdata receivedParts)

    acceptMessagePartCallback :: TVar [ReceivedMessagePart] -> (BSL.ByteString -> Either ParseException (Either a (RawChannel -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (RawChannelHandler, a)))) -> STMc NoRetry '[MultiplexerException] a
    acceptMessagePartCallback parts fn = do
      readTVar parts >>= \case
        [] -> undefined -- TODO error: Trying to accept a message part but none is available
        c:cs -> do
          writeTVar parts cs
          case c of
            ReceivedDataMessagePart cdata ->
              case fn cdata of
                Left ex -> undefined
                Right (Left result) -> pure result
                Right (Right _) -> undefined -- TODO invalid choice
            ReceivedChannelMessagePart channel cdata subParts ->
              case fn cdata of
                Left ex -> undefined
                Right (Left _result) -> undefined -- TODO invalid choice
                Right (Right innerFn) -> do
                  receivedPartsVar <- newTVar subParts
                  let context = ReceiveMessageContext {
                    channel,
                    numCreatedChannels = length subParts,
                    acceptMessagePart = acceptMessagePartCallback receivedPartsVar
                  }
                  (handler, result) <- innerFn channel context
                  unlessM (null <$> readTVar receivedPartsVar) do
                    throwC $ ChannelProtocolException channel.channelId "Received message parts were not handled"
                  rawChannelSetHandler channel handler
                  pure result


data AbortSend = AbortSend
  deriving stock (Eq, Show)

instance Exception AbortSend


sendRawChannelMessage :: MonadIO m => RawChannel -> BSL.ByteString -> m ()
sendRawChannelMessage channel message =
  sendRawChannelMessageDeferred channel \_context -> pure (message, ())

sendRawChannelMessageDeferred :: forall m a. MonadIO m => RawChannel -> (SendMessageContext -> STMc NoRetry '[AbortSend] (BSL.ByteString, a)) -> m a
sendRawChannelMessageDeferred channel msgHook = liftIO do
  -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
  -- STM retries)
  promise :: PromiseEx '[AbortSend] a <- newPromiseIO
  withMVar channel.multiplexer.outboxGuard \_ ->
    atomicallyC do
      sendRawChannelMessageInternal blockUntilReadyBehavior channel \context -> do
        trySTMc (msgHook context) >>= \case
          Left (ex :: AbortSend) -> do
            tryFulfillPromise_ promise (Left (toEx ex))
            pure Nothing
          Right (msg, result) -> do
            tryFulfillPromise_ promise (Right result)
            pure (Just msg)
  awaitEx promise

sendRawChannelMessageDeferred_ :: forall m a. MonadIO m => RawChannel -> (SendMessageContext -> STMc NoRetry '[AbortSend] BSL.ByteString) -> m ()
sendRawChannelMessageDeferred_ channel fn =  sendRawChannelMessageDeferred channel ((,()) <<$>> fn)

-- | Unsafely queue a network message to an unbounded send queue. This function does not block, even if `sendChannelMessage` would block. Queued messages will cause concurrent or following `sendChannelMessage`-calls to block until the queue is flushed.
unsafeQueueRawChannelMessage :: MonadSTMc NoRetry '[ChannelException, MultiplexerException] m => RawChannel -> BSL.ByteString -> m ()
unsafeQueueRawChannelMessage channel message = liftSTMc do
  sendRawChannelMessageInternal unboundedQueueBehavior channel \_context -> pure (Just message)

blockUntilReadyBehavior :: Bool -> STMc Retry exceptions ()
blockUntilReadyBehavior = check

unboundedQueueBehavior :: Bool -> STMc NoRetry exceptions ()
unboundedQueueBehavior _queueIsEmpty = pure ()

sendRawChannelMessageInternal :: (Bool -> STMc canRetry '[ChannelException, MultiplexerException] ()) -> RawChannel -> (SendMessageContext -> STMc NoRetry '[] (Maybe BSL.ByteString)) -> STMc canRetry '[ChannelException, MultiplexerException] ()
sendRawChannelMessageInternal queueBehavior channel@RawChannel{multiplexer} msgHook = do
  -- NOTE At most one message can be queued per STM transaction, so `sendChannelMessage` cannot be changed to STM

  -- Abort if the multiplexer is finished or currently cleaning up
  mapM_ throwC =<< peekFuture (toFuture multiplexer.multiplexerException)

  -- Abort if the channel is closed
  liftSTMc $ verifyChannelIsConnected channel

  msgs <- readTVar multiplexer.outbox

  -- Block until all previously queued messages have been sent, if requested
  queueBehavior (null msgs)

  -- Put the message into the outbox. It will be picked up by the send thread.
  let msg = OutboxSendMessage channel msgHook
  writeTVar multiplexer.outbox (msg:msgs)


createChannelId :: MonadSTMc NoRetry '[] m => TVar ChannelId -> m ChannelId
createChannelId var = stateTVar var \channelId  -> (channelId, channelId + 2)


channelReportProtocolError :: MonadIO m => RawChannel -> String -> m b
channelReportProtocolError = undefined

channelReportException :: MonadIO m => RawChannel -> SomeException -> m b
channelReportException = undefined


rawChannelSetHandler :: MonadSTMc NoRetry '[] m => RawChannel -> RawChannelHandler -> m ()
rawChannelSetHandler channel handler = writeTVar channel.channelHandler (Just handler)


simpleByteStringHandler :: (BSL.ByteString -> QuasarIO ()) -> RawChannelHandler
simpleByteStringHandler fn = \case
  ReceiveMessageContext{numCreatedChannels = 0} -> fn
  resources -> const $ throwM $ ChannelProtocolException resources.channel.channelId "Unexpectedly received new channels"


rawChannelSetSimpleByteStringHandler :: MonadIO m => RawChannel -> (BSL.ByteString -> QuasarIO ()) -> m ()
rawChannelSetSimpleByteStringHandler channel fn = atomically $ rawChannelSetHandler channel (simpleByteStringHandler fn)
{-# DEPRECATED rawChannelSetSimpleByteStringHandler "" #-}


binaryHandler :: forall a. Binary a => (ReceiveMessageContext -> a -> QuasarIO ()) -> RawChannelHandler
binaryHandler fn context message =
  case decodeOrFail message of
    Right ("", _position, parsedCData) -> fn context parsedCData
    Right (leftovers, _position, _parsedCData) -> throwM $ ChannelProtocolException context.channel.channelId $ mconcat ["Failed to parse channel message: ", show (BSL.length leftovers), "b leftover data"]
    Left (_leftovers, _position, msg) -> throwM $ ChannelProtocolException context.channel.channelId $ "Failed to parse channel message: " <> msg


-- | Creates a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
simpleBinaryHandler :: forall a. Binary a => (a -> QuasarIO ()) -> RawChannelHandler
simpleBinaryHandler fn = binaryHandler \case
  ReceiveMessageContext{numCreatedChannels = 0} -> fn
  resources -> const $ throwM $ ChannelProtocolException resources.channel.channelId "Unexpectedly received new channels"


-- * State utilities

modifyStateM :: Monad m => (s -> m s) -> StateT s m ()
modifyStateM fn = State.put =<< lift . fn =<< State.get

stateStateM :: Monad m => (s -> m (a, s)) -> StateT s m a
stateStateM fn = do
  old <- State.get
  (result, new) <- lift $ fn old
  result <$ State.put new
