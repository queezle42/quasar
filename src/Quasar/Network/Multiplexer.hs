module Quasar.Network.Multiplexer (
  -- * Channel type
  Channel(quasar),

  -- * Sending and receiving messages
  MessageId,

  -- ** Sending messages
  MessageConfiguration(..),
  SentMessageResources(..),
  defaultMessageConfiguration,
  channelSend,
  sendChannelMessage,
  sendChannelMessageDeferred,
  unsafeQueueChannelMessage,
  unsafeQueueChannelMessageSimple,
  channelSend_,
  channelSendSimple,
  channelSendSimpleDeferred,

  -- ** Receiving messages
  ReceivedMessageResources(..),
  MessageLength,
  channelSetHandler,
  channelSetSimpleHandler,
  channelSetBinaryHandler,
  channelSetSimpleBinaryHandler,
  ImmediateChannelHandler,
  channelSetImmediateHandler,

  -- ** Exception handling
  MultiplexerException(..),
  ConnectionLostReason(..),
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,

  -- * Create or run a multiplexer
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Monad.Catch
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.State qualified as State
import Control.Monad.Trans (lift)
import Control.Monad.Writer.Strict (WriterT, execWriterT, tell)
import Data.Binary (Binary, Put)
import Data.Binary qualified as Binary
import Data.Binary.Get (Get, Decoder(..), runGetIncremental, pushChunk)
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
type MessageLength = Word64

-- | Amount of created sub-channels
type NewChannelCount = Word32

-- ** Wire format

magicBytes :: BS.ByteString
magicBytes = "qso\0dev\0"

-- | Low level network protocol control message
data MultiplexerMessage
  = ChannelMessage NewChannelCount MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | MultiplexerProtocolError String
  | ChannelProtocolError String
  | InternalError String
  deriving stock (Generic, Show)
  deriving anyclass Binary


-- ** Multiplexer

data OutboxMessage
  = OutboxSendMessage ChannelId NewChannelCount BSL.ByteString
  | OutboxCloseChannel ChannelId
  deriving stock Show

data Multiplexer = Multiplexer {
  side :: MultiplexerSide,
  disposer :: [Disposer],
  multiplexerException :: Promise MultiplexerException,
  multiplexerResult :: Promise (Maybe MultiplexerException),
  receiveThreadCompleted :: Future (),
  -- Set to true after magic bytes have been received
  receivedHeader :: TVar Bool,
  outbox :: TVar [OutboxMessage],
  outboxGuard :: MVar (),
  channelsVar :: TVar (HM.HashMap ChannelId Channel),
  nextReceiveChannelId :: TVar ChannelId,
  nextSendChannelId :: TVar ChannelId
}
instance Resource Multiplexer where
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
  | LocalException SomeException
  | RemoteException String
  | ProtocolException String
  | ReceivedProtocolException String
  | ChannelProtocolException ChannelId String
  | ReceivedChannelProtocolException ChannelId String
  deriving stock Show

instance Exception MultiplexerException where
  displayException (InvalidMagicBytes received) =
    mconcat ["Magic bytes don't match: Expected ", show magicBytes, ", got ", show received]
  displayException ex = show ex

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

-- ** Channel

data Channel = Channel {
  multiplexer :: Multiplexer,
  quasar :: Quasar,
  channelId :: ChannelId,
  channelHandler :: TVar (Maybe InternalHandler),
  parent :: Maybe Channel,
  children :: TVar (HM.HashMap ChannelId Channel),
  nextSendMessageId :: TVar MessageId,
  nextReceiveMessageId :: TVar MessageId,
  receivedCloseMessage :: TVar Bool,
  sentCloseMessage :: TVar Bool
}

instance Resource Channel where
  getDisposer channel = getDisposer channel.quasar

newRootChannel :: Multiplexer -> QuasarIO Channel
newRootChannel multiplexer = do
  quasar <- askQuasar
  channel <- liftIO do
    channelHandler <- newTVarIO Nothing
    children <- newTVarIO mempty
    nextSendMessageId <- newTVarIO 0
    nextReceiveMessageId <- newTVarIO 0
    receivedCloseMessage <- newTVarIO False
    sentCloseMessage <- newTVarIO False

    pure Channel {
      multiplexer,
      quasar,
      channelId = 0,
      channelHandler,
      parent = Nothing,
      children,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

  registerDisposeTransactionIO_ $ sendChannelCloseMessage channel

  pure channel

newChannelSTM :: Channel -> ChannelId -> STM Channel
newChannelSTM parent@Channel{multiplexer, quasar=parentQuasar} channelId = do
  -- Channels inherit their parents close state
  parentReceivedCloseMessage <- readTVar parent.receivedCloseMessage
  parentSentCloseMessage <- readTVar parent.sentCloseMessage

  quasar <- newResourceScopeSTM parentQuasar
  channelHandler <- newTVar Nothing
  children <- newTVar mempty
  nextSendMessageId <- newTVar 0
  nextReceiveMessageId <- newTVar 0
  receivedCloseMessage <- newTVar parentReceivedCloseMessage
  sentCloseMessage <- newTVar parentSentCloseMessage

  let channel = Channel {
    multiplexer,
    quasar,
    channelId,
    channelHandler,
    parent = Just parent,
    children,
    nextSendMessageId,
    nextReceiveMessageId,
    receivedCloseMessage,
    sentCloseMessage
  }

  -- Attach to parent
  modifyTVar parent.children $ HM.insert channelId channel

  runQuasarSTM quasar $ registerDisposeTransaction_ $ sendChannelCloseMessage channel

  modifyTVar multiplexer.channelsVar $ HM.insert channelId channel

  pure channel

sendChannelCloseMessage :: Channel -> STM ()
sendChannelCloseMessage channel = do
  alreadySent <- readTVar channel.sentCloseMessage
  unless alreadySent do
    modifyTVar channel.multiplexer.outbox (OutboxCloseChannel channel.channelId :)
    -- Mark as closed and propagate close state to children
    markAsClosed channel
    cleanupChannel channel
  where
    markAsClosed :: Channel -> STM ()
    markAsClosed markChannel = do
      writeTVar markChannel.sentCloseMessage True
      children <- readTVar markChannel.children
      mapM_ markAsClosed children

setReceivedChannelCloseMessage :: Channel -> STM ()
setReceivedChannelCloseMessage channel = do
  writeTVar channel.receivedCloseMessage True
  children <- readTVar channel.children
  mapM_ setReceivedChannelCloseMessage children
  cleanupChannel channel

cleanupChannel :: Channel -> STM ()
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

verifyChannelIsConnected :: Channel -> STM ()
verifyChannelIsConnected channel = do
  whenM (readTVar channel.sentCloseMessage) $ throwM ChannelNotConnected
  whenM (readTVar channel.receivedCloseMessage) $ throwM ChannelNotConnected

data ChannelException = ChannelNotConnected
  deriving stock Show
  deriving anyclass Exception

-- ** Channel message interface

type InternalHandler = ReceivedMessageResources -> IO InternalMessageHandler
newtype InternalMessageHandler = InternalMessageHandler (Maybe BS.ByteString -> IO InternalMessageHandler)

type ImmediateChannelHandler = ReceivedMessageResources -> QuasarIO (BS.ByteString -> IO (), QuasarIO ())

data MessageConfiguration = MessageConfiguration {
  closeChannel :: Bool,
  createChannels :: NewChannelCount
}

defaultMessageConfiguration :: MessageConfiguration
defaultMessageConfiguration = MessageConfiguration {
  closeChannel = False,
  createChannels = 0
}

data SentMessageResources = SentMessageResources {
  messageId :: MessageId,
  createdChannels :: [Channel]
  --unixFds :: Undefined
}
data ReceivedMessageResources = ReceivedMessageResources {
  messageLength :: MessageLength,
  messageId :: MessageId,
  createdChannels :: [Channel]
  --unixFds :: Undefined
}


-- * Implementation

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling `dispose`; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> (Channel -> QuasarIO ()) -> Connection -> m ()
runMultiplexer side channelSetupHook connection = liftQuasarIO $ mask_ do
  (rootChannel, result) <- newMultiplexerInternal side connection
  runQuasarIO rootChannel.quasar $ channelSetupHook rootChannel
  mException <- await result
  mapM_ throwM mException

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (MonadQuasar m, MonadIO m) => MultiplexerSide -> Connection -> m Channel
newMultiplexer side connection = liftQuasarIO $ mask_ do
  exceptionSink <- askExceptionSink
  (rootChannel, result) <- newMultiplexerInternal side connection
  -- TODO review the uninterruptibleMask (currently ensures the exception is delivered - can be improved by properly using the ExceptionSink now)
  async_ $ liftIO $ uninterruptibleMask_ do
    mException <- await result
    mapM_ (atomically . throwToExceptionSink exceptionSink) mException
  pure rootChannel

newMultiplexerInternal :: MultiplexerSide -> Connection -> QuasarIO (Channel, Future (Maybe MultiplexerException))
newMultiplexerInternal side connection = disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by `disposeOnError`, so it can be used as a disposable
  -- without accidentally disposing external resources.
  resourceManager <- askResourceManager

  outbox <- liftIO $ newTVarIO []
  multiplexerException <- newPromise
  multiplexerResult <- newPromise
  outboxGuard <- liftIO $ newMVar ()
  receivedHeader <- liftIO $ newTVarIO False
  nextReceiveChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 2 else 1
  nextSendChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 1 else 2

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    multiplexer <- mfix \multiplexer -> do
      worker <- askIOWorker
      exSink <- catchSink (multiplexerExceptionHandler multiplexer) <$> askExceptionSink

      receiveTask <- unmanagedAsync worker exSink $
        receiveThread multiplexer (receiveCheckEOF connection)
      sendTask <- unmanagedAsync worker exSink $
        sendThread multiplexer connection.send

      let
        sendThreadCompleted = awaitSuccessOrFailure sendTask
        receiveThreadCompleted = awaitSuccessOrFailure receiveTask

      registerDisposeActionIO do
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
          fulfillPromise multiplexerException $ ConnectionLost CloseTimeoutReached

        sf <- disposeEventuallyIO sendTask
        rf <- disposeEventuallyIO receiveTask
        await $ sf <> rf

        connection.close

        fulfillPromise multiplexerResult =<< peekFuture (toFuture multiplexerException)

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


multiplexerExceptionHandler :: Multiplexer -> SomeException -> STM ()
multiplexerExceptionHandler multiplexer (toMultiplexerException -> ex) = do
  unlessM (tryFulfillPromiseSTM multiplexer.multiplexerException ex) do
    traceM $ "Multiplexer ignored exception: " <> displayException ex
  disposeEventually_ multiplexer

toMultiplexerException :: SomeException -> MultiplexerException
-- Exception is a MultiplexerException already
toMultiplexerException (fromException -> Just ex) = ex
-- Otherwise it's a local exception (usually from application code) (may be on a multiplexer thread)
toMultiplexerException (fromException -> Just (AsyncException ex)) = LocalException ex
toMultiplexerException ex = LocalException ex

-- | Await a lost connection.
--
-- For module-internal use only, since it does not follow awaitable best practices (it never completes when the the connection
-- does not fail).
awaitConnectionLost :: Multiplexer -> Future ()
awaitConnectionLost multiplexer =
   do
    r <- await multiplexer.multiplexerException
    unsafeAwaitSTM $ check (isConnectionLost r)
  where
    isConnectionLost :: MultiplexerException -> Bool
    isConnectionLost (ConnectionLost _) = True
    isConnectionLost _ = False


sendThread :: Multiplexer -> (BSL.ByteString -> IO ()) -> IO ()
sendThread multiplexer sendFn = do
  case multiplexer.side of
    MultiplexerSideA -> send $ Binary.putByteString magicBytes
    MultiplexerSideB -> do
      -- Block sending until magic bytes have been received
      atomically $ check =<< readTVar multiplexer.receivedHeader
  evalStateT sendLoop 0
  where
    send :: MonadIO m => Put -> m ()
    send chunks = liftIO $ sendFn (Binary.runPut chunks) `catchAll` (throwM . ConnectionLost . SendFailed)

    sendLoop :: StateT ChannelId IO ()
    sendLoop = do
      join $ liftIO $ atomically do
        peekFutureSTM (toFuture multiplexer.multiplexerException) >>= \case
          -- Send exception (if required for that exception type) and then terminate send loop
          Just fatalException -> pure $ sendException fatalException
          Nothing -> do
            messages <- swapTVar multiplexer.outbox []
            case messages of
              -- Exit when the receive thread has stopped and there is no error and no message left to send
              [] -> pure () <$ awaitSTM multiplexer.receiveThreadCompleted
              _ -> pure do
                bytes <- execWriterT do
                  -- outbox is a list that is used as a queue, so it has to be reversed to preserve the correct order
                  mapM_ formatMessage (reverse messages)
                liftIO $ send bytes
                sendLoop

    sendException :: MultiplexerException -> StateT ChannelId IO ()
    sendException (ConnectionLost _) = pure ()
    sendException (InvalidMagicBytes _) = pure ()
    sendException (LocalException ex) = liftIO $ send $ Binary.put $ InternalError $ show ex
    sendException (RemoteException _) = pure ()
    sendException (ProtocolException message) = liftIO $ send $ Binary.put $ MultiplexerProtocolError message
    sendException (ReceivedProtocolException _) = pure ()
    sendException (ChannelProtocolException channelId message) = do
      msg <- execWriterT do
        switchToChannel channelId
        tell $ Binary.put $ ChannelProtocolError message
      send msg
    sendException (ReceivedChannelProtocolException _ _) = pure ()

    formatMessage :: OutboxMessage -> WriterT Put (StateT ChannelId IO) ()
    formatMessage (OutboxSendMessage channelId newChannelCount message) = do
      switchToChannel channelId
      tell do
        Binary.put (ChannelMessage newChannelCount messageLength)
        Binary.putLazyByteString message
      where
        messageLength = fromIntegral $ BSL.length message
    formatMessage (OutboxCloseChannel channelId) = do
      switchToChannel channelId
      tell $ Binary.put CloseChannel

    switchToChannel :: ChannelId -> WriterT Put (StateT ChannelId IO) ()
    switchToChannel channelId = do
      currentChannelId <- State.get
      when (channelId /= currentChannelId) do
        tell $ Binary.put $ SwitchChannel channelId
        State.put channelId


-- | Internal state of the `receiveThread` function.
type ReceiveThreadState = Maybe Channel

receiveThread :: Multiplexer -> IO BS.ByteString -> IO ()
receiveThread multiplexer readFn = do
  rootChannel <- lookupChannel 0
  chunk <- case multiplexer.side of
    MultiplexerSideA -> readBytes
    MultiplexerSideB -> checkMagicBytes
  evalStateT (multiplexerLoop rootChannel) chunk
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

    multiplexerLoop :: ReceiveThreadState -> StateT BS.ByteString IO ()
    multiplexerLoop prevState = do
      msg <- getMultiplexerMessage
      mNextState <- execReceivedMultiplexerMessage prevState msg
      mapM_ multiplexerLoop mNextState

    lookupChannel :: ChannelId -> IO (Maybe Channel)
    lookupChannel channelId = do
      HM.lookup channelId <$> readTVarIO multiplexer.channelsVar

    runGet :: forall a. Get a -> (forall b. String -> IO b) -> StateT BS.ByteString IO a
    runGet get errorHandler = do
      stateStateM $ liftIO . stepDecoder . pushChunk (runGetIncremental get)
      where
        stepDecoder :: Decoder a -> IO (a, BS.ByteString)
        stepDecoder (Fail _ _ errMsg) = errorHandler errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< readBytes
        stepDecoder (Done leftovers _ msg) = pure (msg, leftovers)

    getMultiplexerMessage :: StateT BS.ByteString IO MultiplexerMessage
    getMultiplexerMessage =
      runGet Binary.get \errMsg ->
        protocolException $ "Failed to parse protocol message: " <> errMsg

    execReceivedMultiplexerMessage :: ReceiveThreadState -> MultiplexerMessage -> StateT BS.ByteString IO (Maybe ReceiveThreadState)
    execReceivedMultiplexerMessage Nothing (ChannelMessage _ _) = undefined
    execReceivedMultiplexerMessage state@(Just channel) (ChannelMessage newChannelCount messageLength) = do
      join $ liftIO $ atomically do
        closedByRemote <- readTVar channel.receivedCloseMessage
        sentClose <- readTVar channel.sentCloseMessage
        -- Create channels even if the current channel has been closed, to stay in sync with the remote side
        createdChannelIds <- stateTVar multiplexer.nextReceiveChannelId (createChannelIds newChannelCount)
        createdChannels <- mapM (newChannelSTM channel) createdChannelIds
        pure do
          -- Receiving messages after the remote side closed a channel is a protocol error
          when closedByRemote $ protocolException $
            mconcat ["Received message for invalid channel ", show channel.channelId, " (channel is closed)"]
          if sentClose
            -- Drop received messages when the channel has been closed on the local side
            then dropBytes messageLength
            else receiveChannelMessage channel createdChannels messageLength
          pure $ Just state

    execReceivedMultiplexerMessage _ (SwitchChannel channelId) = liftIO do
      lookupChannel channelId >>= \case
        Nothing -> protocolException $
          mconcat ["Failed to switch to channel ", show channelId, " (invalid id)"]
        Just channel -> do
          receivedClose <- readTVarIO channel.receivedCloseMessage
          when receivedClose $ protocolException $
            mconcat ["Failed to switch to channel ", show channelId, " (channel is closed)"]
          pure (Just (Just channel))

    execReceivedMultiplexerMessage Nothing CloseChannel = undefined
    execReceivedMultiplexerMessage (Just channel) CloseChannel = liftIO do
      atomically do
        setReceivedChannelCloseMessage channel
        sendChannelCloseMessage channel
      disposeEventuallyIO_ channel
      pure if channel.channelId /= 0
        then Just Nothing
        -- Terminate receive thread
        else Nothing

    execReceivedMultiplexerMessage _ (MultiplexerProtocolError msg) = throwM $ RemoteException $
      "Remote closed connection because of a multiplexer protocol error: " <> msg
    execReceivedMultiplexerMessage Nothing (ChannelProtocolError msg) = undefined
    execReceivedMultiplexerMessage (Just channel) (ChannelProtocolError msg) =
      throwM $ ChannelProtocolException channel.channelId msg
    execReceivedMultiplexerMessage _ (InternalError msg) =
      throwM $ RemoteException msg

    receiveChannelMessage :: Channel -> [Channel] -> MessageLength -> StateT BS.ByteString IO ()
    receiveChannelMessage channel createdChannels messageLength = do
      modifyStateM \chunk -> liftIO do
        messageId <- atomically $ stateTVar channel.nextReceiveMessageId (\x -> (x, x + 1))
        -- NOTE blocks until a channel handler is set
        handler <- atomically $ maybe retry pure =<< readTVar channel.channelHandler

        messageHandler <- handler ReceivedMessageResources {
          createdChannels,
          messageId,
          messageLength
        }
        runHandler messageHandler messageLength chunk
      where
        runHandler :: InternalMessageHandler -> MessageLength -> BS.ByteString -> IO BS.ByteString
        -- Signal to handler, that receiving is completed
        runHandler (InternalMessageHandler fn) 0 leftovers = leftovers <$ fn Nothing
        -- Read more data
        runHandler handler remaining (BS.null -> True) = runHandler handler remaining =<< readBytes
        -- Feed remaining data into handler
        runHandler (InternalMessageHandler fn) remaining chunk
          | chunkLength <= remaining = do
            next <- fn (Just chunk)
            runHandler next (remaining - chunkLength) ""
          | otherwise = do
            let (finalChunk, leftovers) = BS.splitAt (fromIntegral remaining) chunk
            next <- fn (Just finalChunk)
            runHandler next 0 leftovers
          where
            chunkLength = fromIntegral $ BS.length chunk

    dropBytes :: MessageLength -> StateT BS.ByteString IO ()
    dropBytes = modifyStateM . go
      where
        go :: MessageLength -> BS.ByteString -> IO BS.ByteString
        go remaining chunk
          | chunkLength <= remaining = do
            go (remaining - chunkLength) =<< readBytes
          | otherwise = do
            pure $ BS.drop (fromIntegral remaining) chunk
          where
            chunkLength = fromIntegral $ BS.length chunk


channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
channelSend = sendChannelMessage
{-# DEPRECATED channelSend "Use sendChannelMessage instead" #-}

sendChannelMessage :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
sendChannelMessage channel@Channel{multiplexer} messageConfiguration payload messageIdHook = liftIO do
  -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
  -- STM retries)
  withMVar multiplexer.outboxGuard \_ ->
    atomically $ sendChannelMessageInternal BlockUntilReady channel messageConfiguration (pure payload) messageIdHook

sendChannelMessageDeferred :: MonadIO m => Channel -> MessageConfiguration -> STM BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
sendChannelMessageDeferred channel@Channel{multiplexer} messageConfiguration payloadHook messageIdHook = liftIO do
  -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
  -- STM retries)
  withMVar multiplexer.outboxGuard \_ ->
    atomically $ sendChannelMessageInternal BlockUntilReady channel messageConfiguration payloadHook messageIdHook

-- | Unsafely queue a network message to an unbounded send queue. This function does not block, even if `sendChannelMessage` would block. Queued messages will cause concurrent or following `sendChannelMessage`-calls to block until the queue is flushed.
unsafeQueueChannelMessage :: Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> STM SentMessageResources
unsafeQueueChannelMessage channel messageConfiguration payload =
  sendChannelMessageInternal UnboundedQueue channel messageConfiguration (pure payload)

unsafeQueueChannelMessageSimple :: MonadSTM m => Channel -> BSL.ByteString -> m ()
unsafeQueueChannelMessageSimple channel msg = liftSTM do
  unsafeQueueChannelMessage channel defaultMessageConfiguration msg (const (pure ())) >>=
    \case
      -- Pattern match verifies no channels are created due to a bug
      SentMessageResources{createdChannels=[]} -> pure ()
      _ -> unreachableCodePathM


data QueueBehavior = BlockUntilReady | UnboundedQueue

sendChannelMessageInternal :: QueueBehavior -> Channel -> MessageConfiguration -> STM BSL.ByteString -> (MessageId -> STM ()) -> STM SentMessageResources
sendChannelMessageInternal queueBehavior channel@Channel{multiplexer} MessageConfiguration{closeChannel, createChannels} payloadHook messageIdHook = do
  -- NOTE At most one message can be queued per STM transaction, so `sendChannelMessage` cannot be changed to STM

  -- Abort if the multiplexer is finished or currently cleaning up
  mapM_ throwM =<< peekFutureSTM (toFuture multiplexer.multiplexerException)

  -- Abort if the channel is closed
  verifyChannelIsConnected channel

  msgs <- readTVar multiplexer.outbox

  case queueBehavior of
    BlockUntilReady ->
      -- Block until all previously queued messages have been sent.
      check $ null msgs
    UnboundedQueue -> pure ()

  payload <- payloadHook

  -- Put the message into the outbox. It will be picked up by the send thread.
  let msg = OutboxSendMessage channel.channelId createChannels payload
  writeTVar multiplexer.outbox (msg:msgs)

  messageId <- stateTVar channel.nextSendMessageId (\x -> (x, x + 1))
  messageIdHook messageId

  when closeChannel do
    sendChannelCloseMessage channel
    disposeEventually_ channel

  createdChannelIds <- stateTVar multiplexer.nextSendChannelId (createChannelIds createChannels)
  createdChannels <- mapM (newChannelSTM channel) createdChannelIds

  pure SentMessageResources {
    messageId,
    createdChannels
  }

createChannelIds :: NewChannelCount -> ChannelId -> ([ChannelId], ChannelId)
createChannelIds amount firstId = (channelIds, nextId)
  where
    channelIds = take (fromIntegral amount) [firstId, firstId + 2..]
    nextId = firstId + fromIntegral amount * 2

channelSend_ :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> m SentMessageResources
channelSend_ channel configuration msg = channelSend channel configuration msg (const (pure ()))

channelSendSimple :: MonadIO m => Channel -> BSL.ByteString -> m ()
channelSendSimple channel msg = liftIO do
  -- Pattern match verifies no channels are created due to a bug
  SentMessageResources{createdChannels=[]} <- channelSend channel defaultMessageConfiguration msg (const (pure ()))
  pure ()

channelSendSimpleDeferred :: MonadIO m => Channel -> STM BSL.ByteString -> m ()
channelSendSimpleDeferred channel payloadHook = liftIO do
  -- Pattern match verifies no channels are created due to a bug
  SentMessageResources{createdChannels=[]} <- sendChannelMessageDeferred channel defaultMessageConfiguration payloadHook (const (pure ()))
  pure ()

channelReportProtocolError :: MonadIO m => Channel -> String -> m b
channelReportProtocolError = undefined

channelReportException :: MonadIO m => Channel -> SomeException -> m b
channelReportException = undefined


channelSetInternalHandler :: MonadIO m => Channel -> InternalHandler -> m ()
channelSetInternalHandler channel handler = liftIO $ atomically $ writeTVar channel.channelHandler (Just handler)

channelSetHandler :: MonadIO m => Channel -> (ReceivedMessageResources -> BSL.ByteString -> QuasarIO ()) -> m ()
channelSetHandler channel fn = channelSetInternalHandler channel bytestringHandler
  where
    bytestringHandler :: ReceivedMessageResources -> IO InternalMessageHandler
    bytestringHandler resources = pure $ InternalMessageHandler $ go []
      where
        go :: [BS.ByteString] -> Maybe BS.ByteString -> IO InternalMessageHandler
        go accum (Just chunk) = pure $ InternalMessageHandler $ go (chunk:accum)
        go accum Nothing =
          InternalMessageHandler (const unreachableCodePathM) <$ do
            execForeignQuasarIO channel.quasar do
              fn resources $ BSL.fromChunks (reverse accum)

channelSetSimpleHandler :: MonadIO m => Channel -> (BSL.ByteString -> QuasarIO ()) -> m ()
channelSetSimpleHandler channel fn = channelSetHandler channel \case
  ReceivedMessageResources{createdChannels=[]} -> fn
  _ -> const $ throwM $ ChannelProtocolException channel.channelId "Unexpectedly received new channels"


channelSetImmediateHandler :: MonadIO m => Channel -> ImmediateChannelHandler -> m ()
channelSetImmediateHandler channel handler = undefined -- liftIO $ atomically $ writeTVar channel.channelHandler (Just handler)

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (ReceivedMessageResources -> a -> QuasarIO ()) -> m ()
channelSetBinaryHandler channel fn = channelSetInternalHandler channel binaryHandler
  where
    binaryHandler :: ReceivedMessageResources -> IO InternalMessageHandler
    binaryHandler resources = pure $ InternalMessageHandler $ stepDecoder $ runGetIncremental Binary.get
      where
        stepDecoder :: Decoder a -> Maybe BS.ByteString -> IO InternalMessageHandler
        stepDecoder (Fail _ _ errMsg) _ = throwM $ ChannelProtocolException channel.channelId $ "Failed to parse channel message: " <> errMsg
        stepDecoder (Partial feedFn) chunk@(Just _) = pure $ InternalMessageHandler $ stepDecoder (feedFn chunk)
        stepDecoder (Partial feedFn) Nothing = throwM $ ChannelProtocolException channel.channelId $ "End of message has been reached but decoder expects more data"
        stepDecoder (Done "" _ result) Nothing = InternalMessageHandler (const impossibleCodePathM) <$ runHandler result
        stepDecoder (Done _ bytesRead msg) _ = throwM $ ChannelProtocolException channel.channelId $
          mconcat ["Decoder failed to consume complete message (", show (fromIntegral resources.messageLength - bytesRead), " bytes left)"]

        runHandler :: a -> IO ()
        runHandler result = execForeignQuasarIO channel.quasar (fn resources result)

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetSimpleBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (a -> QuasarIO ()) -> m ()
channelSetSimpleBinaryHandler channel fn = channelSetBinaryHandler channel \case
  ReceivedMessageResources{createdChannels=[]} -> fn
  _ -> const $ throwM $ ChannelProtocolException channel.channelId "Unexpectedly received new channels"



-- * State utilities

modifyStateM :: Monad m => (s -> m s) -> StateT s m ()
modifyStateM fn = State.put =<< lift . fn =<< State.get

stateStateM :: Monad m => (s -> m (a, s)) -> StateT s m a
stateStateM fn = do
  old <- State.get
  (result, new) <- lift $ fn old
  result <$ State.put new
