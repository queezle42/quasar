module Quasar.Network.Multiplexer (
  -- * Channel type
  Channel,

  -- * Sending and receiving messages
  MessageId,

  -- ** Sending messages
  MessageConfiguration(..),
  SentMessageResources(..),
  defaultMessageConfiguration,
  channelSend,
  channelSend_,
  channelSendSimple,

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
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,

  -- * Create or run a multiplexer
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Concurrent.STM
import Control.DeepSeq (rnf)
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
import Quasar.Async
import Quasar.Async.Unmanaged
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Connection
import Quasar.Prelude
import Quasar.ResourceManager
import Quasar.Timer (newUnmanagedDelay)

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
  deriving anyclass (Binary)


-- ** Multiplexer

data Multiplexer = Multiplexer {
  side :: MultiplexerSide,
  disposable :: Disposable,
  inbox :: TMVar (BS.ByteString),
  outbox :: TMVar (ChannelId, NewChannelCount, BSL.ByteString),
  outboxGuard :: MVar (),
  -- Set to true after magic bytes have been received
  receivedHeader :: TVar Bool,
  closeChannelOutbox :: TVar [ChannelId],
  channelsVar :: TVar (HM.HashMap ChannelId Channel),
  multiplexerResult :: AsyncVar MultiplexerException
}
instance IsDisposable Multiplexer where
  toDisposable = (.disposable)

-- | 'MultiplexerSideA' describes the initiator of a connection, i.e. the client in most cases.
--
-- Side A will send multiplexer headers before the server sends a response.
--
-- In cases where there is no clear initiator or client/server relation, the side which usually sends the first message
-- should be side A.
data MultiplexerSide = MultiplexerSideA | MultiplexerSideB
  deriving stock (Eq, Show)

data MultiplexerException
  = ConnectionClosed
  | ConnectionLost SomeException
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

protocolException :: MonadThrow m => String -> m a
protocolException = throwM . ProtocolException

-- ** Channel

data Channel = Channel {
  multiplexer :: Multiplexer,
  resourceManager :: ResourceManager,
  channelId :: ChannelId,
  channelHandler :: TVar (Maybe InternalHandler),
  nextSendMessageId :: TVar MessageId,
  nextReceiveMessageId :: TVar MessageId,
  receivedCloseMessage :: TVar Bool,
  sentCloseMessage :: TVar Bool
  --children :: [Channel]
}

instance IsDisposable Channel where
  toDisposable channel = toDisposable channel.resourceManager

instance IsResourceManager Channel where
  toResourceManager channel = channel.resourceManager

newChannel :: Multiplexer -> ChannelId -> ResourceManagerIO Channel
newChannel multiplexer channelId = do
  resourceManager <- newResourceManager
  liftIO do
    channelHandler <- newTVarIO Nothing
    nextSendMessageId <- newTVarIO 0
    nextReceiveMessageId <- newTVarIO 0
    receivedCloseMessage <- newTVarIO False
    sentCloseMessage <- newTVarIO False

    let channel = Channel {
      multiplexer,
      resourceManager,
      channelId,
      channelHandler,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

    attachDisposeAction_ resourceManager (sendChannelCloseMessage channel)

    pure channel

sendChannelCloseMessage :: Channel -> IO ()
sendChannelCloseMessage channel = do
  atomically do
    hasAlreadySentClose <- swapTVar channel.sentCloseMessage True
    unless hasAlreadySentClose do
      -- TODO check parent close state (or propagate close state to children)
      modifyTVar channel.multiplexer.closeChannelOutbox (channel.channelId :)

data ChannelException = ChannelNotConnected
  deriving stock Show
  deriving anyclass Exception

-- ** Channel message interface

type InternalHandler = ReceivedMessageResources -> IO InternalMessageHandler
newtype InternalMessageHandler = InternalMessageHandler (Maybe BS.ByteString -> IO InternalMessageHandler)

type ImmediateChannelHandler = ReceivedMessageResources -> ResourceManagerIO (BS.ByteString -> IO (), ResourceManagerIO ())

newtype MessageConfiguration = MessageConfiguration {
  createChannels :: NewChannelCount
}

defaultMessageConfiguration :: MessageConfiguration
defaultMessageConfiguration = MessageConfiguration {
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
runMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> (Channel -> ResourceManagerIO ()) -> a -> m ()
runMultiplexer side channelSetupHook (toSocketConnection -> connection) = liftResourceManagerIO $ mask_ do
  (rootChannel, result) <- newMultiplexerInternal side connection
  onResourceManager rootChannel $ channelSetupHook rootChannel
  await result >>= \case
    ConnectionClosed -> pure ()
    exception -> throwM exception

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> a -> m Channel
newMultiplexer side (toSocketConnection -> connection) = liftResourceManagerIO $ mask_ do
  resourceManager <- askResourceManager
  (rootChannel, result) <- newMultiplexerInternal side connection
  async_ $ liftIO $ uninterruptibleMask_ do
    await result >>= \case
      ConnectionClosed -> pure ()
      exception -> throwToResourceManager resourceManager exception
  pure rootChannel

newMultiplexerInternal :: MultiplexerSide -> Connection -> ResourceManagerIO (Channel, Awaitable MultiplexerException)
newMultiplexerInternal side connection = disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by `disposeOnError`, so it can be used as a disposable
  -- without accidentally disposing external resources.
  resourceManager <- askResourceManager

  inbox <- liftIO newEmptyTMVarIO
  outbox <- liftIO $ newEmptyTMVarIO
  multiplexerResult <- newAsyncVar
  outboxGuard <- liftIO $ newMVar ()
  receivedHeader <- liftIO $ newTVarIO False
  closeChannelOutbox <- liftIO $ newTVarIO mempty

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    --receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
    --sendNextChannelId = if side == MultiplexerSideA then 1 else 2
    let multiplexer = Multiplexer {
      side,
      disposable = toDisposable resourceManager,
      inbox,
      outbox,
      outboxGuard,
      receivedHeader,
      closeChannelOutbox,
      channelsVar,
      multiplexerResult
    }

    lockResourceManager do
      receiveThread <- unmanagedAsyncWithHandler (multiplexerExceptionHandler multiplexer) (liftIO (receiveThread connection inbox))
      multiplexerThread <- unmanagedAsyncWithHandler (multiplexerExceptionHandler multiplexer) (liftIO (multiplexerThread multiplexer))
      sendThread <- unmanagedAsyncWithHandler (multiplexerExceptionHandler multiplexer) (liftIO (sendThread connection multiplexer))

      registerAsyncDisposeAction do
        -- NOTE The network connection should be closed automatically when the root channel is closed.
        -- This action exists to ensure the network connection is not blocking a resource manager for an unbounded
        -- amount of time.

        timeout <- newUnmanagedDelay 2000000

        -- Valid reasons to abort the multiplexer threads:
        awaitAny [
          -- Timeout reached
          await timeout,
          -- Connection is lost, so no exit/error messages need to be sent
          connectionLost multiplexer,
          -- Send *and* receive thread have terminated on their own, which happens after final messages (i.e. root
          -- channel closed or error messages) have been exchanged.
          do
            awaitSuccessOrFailure sendThread
            awaitSuccessOrFailure multiplexerThread
          ]

        putAsyncVar_ multiplexerResult $ ConnectionLost undefined -- "Reached timeout while performing graceful close"
        dispose receiveThread
        dispose sendThread
        dispose multiplexerThread
        connection.close

    newChannel multiplexer 0

  -- TODO merge resource managers instead of building a loop
  attachDisposable rootChannel resourceManager

  pure (rootChannel, toAwaitable multiplexerResult)


multiplexerExceptionHandler :: Multiplexer -> SomeException -> IO ()
multiplexerExceptionHandler multiplexer (toMultiplexerException -> ex) = do
  unlessM
    do putAsyncVar multiplexer.multiplexerResult ex
    do traceIO $ "Multiplexer ignored exception: " <> displayException ex
  disposeEventually_ multiplexer

toMultiplexerException :: SomeException -> MultiplexerException
-- Exception is a MultiplexerException already
toMultiplexerException (fromException -> Just ex) = ex
-- Otherwise it's a local exception (usually from application code)
toMultiplexerException ex = LocalException ex

-- | Await a lost connection.
--
-- For module-internal use only, since it does not follow awaitable rules (it never completes when the the connection
-- does not fail).
connectionLost :: Multiplexer -> Awaitable ()
connectionLost multiplexer =
  unsafeAwaitSTM do
    r <- readAsyncVarSTM multiplexer.multiplexerResult
    check (isConnectionLost r)
  where
    isConnectionLost :: MultiplexerException -> Bool
    isConnectionLost (ConnectionLost _) = True
    isConnectionLost _ = False


receiveThread :: Connection -> TMVar BS.ByteString -> IO ()
receiveThread connection inbox = forever do
  chunk <- connection.receive `catchAll` (throwM . ConnectionLost)
  atomically $ putTMVar inbox chunk

sendThread :: Connection -> Multiplexer -> IO ()
sendThread connection multiplexer = do
  case multiplexer.side of
    MultiplexerSideA -> send $ Binary.putByteString magicBytes
    MultiplexerSideB -> do
      -- Block sending until magic bytes have been received
      atomically $ check =<< readTVar multiplexer.receivedHeader
  evalStateT sendLoop 0
  where
    sendLoop :: StateT ChannelId IO ()
    sendLoop = do
      join $ liftIO $ atomically do
        tryReadAsyncVarSTM multiplexer.multiplexerResult >>= \case
          -- Send exception (if required for that exception type) and then terminate send loop
          Just fatalException -> pure $ liftIO $ sendException fatalException
          Nothing -> do
            mMessage <- tryTakeTMVar multiplexer.outbox
            closeChannelList <- swapTVar multiplexer.closeChannelOutbox []
            case (mMessage, closeChannelList) of
              (Nothing, []) -> retry
              _ -> pure ()
            pure do
              msg <- execWriterT do
                formatChannelMessage mMessage
                -- closeChannelList is used as a queue, so it has to be reversed to keep the order of close messages
                formatCloseMessages (reverse closeChannelList)
              liftIO $ send msg
              sendLoop
    send :: Put -> IO ()
    send chunks = connection.send (Binary.runPut chunks) `catchAll` (throwM . ConnectionLost)
    sendException :: MultiplexerException -> IO ()
    sendException ConnectionClosed = pure ()
    sendException (ConnectionLost _) = pure ()
    sendException (InvalidMagicBytes _) = pure ()
    sendException (LocalException ex) = undefined
    sendException (RemoteException _) = pure ()
    sendException (ProtocolException message) = undefined
    sendException (ReceivedProtocolException _) = pure ()
    sendException (ChannelProtocolException channelId message) = undefined
    sendException (ReceivedChannelProtocolException _ _) = pure ()
    formatChannelMessage :: Maybe (ChannelId, NewChannelCount, BSL.ByteString) -> WriterT Put (StateT ChannelId IO) ()
    formatChannelMessage Nothing = pure ()
    formatChannelMessage (Just (channelId, newChannelCount, message)) = do
      switchToChannel channelId
      tell do
        Binary.put (ChannelMessage newChannelCount messageLength)
        Binary.putLazyByteString message
      where
        messageLength = fromIntegral $ BSL.length message
    formatCloseMessages :: [ChannelId] -> WriterT Put (StateT ChannelId IO) ()
    formatCloseMessages [] = pure mempty
    formatCloseMessages (i:is) = do
      switchToChannel i
      tell $ Binary.put CloseChannel
      formatCloseMessages is
    switchToChannel :: ChannelId -> WriterT Put (StateT ChannelId IO) ()
    switchToChannel channelId = do
      currentChannelId <- State.get
      when (channelId /= currentChannelId) do
        tell $ Binary.put $ SwitchChannel channelId
        State.put channelId


multiplexerThread :: Multiplexer -> IO ()
multiplexerThread multiplexer = do
  rootChannel <- lookupChannel 0
  chunk <- case multiplexer.side of
    MultiplexerSideA -> read
    MultiplexerSideB -> checkMagicBytes
  evalStateT (multiplexerLoop rootChannel) chunk
  where
    read :: IO BS.ByteString
    read = atomically $ takeTMVar multiplexer.inbox

    -- | Reads and verifies magic bytes.  Returns bytes left over from the received chunk(s).
    checkMagicBytes :: IO BS.ByteString
    checkMagicBytes = checkMagicBytes' ""
      where
        magicBytesLength = BS.length magicBytes
        checkMagicBytes' :: BS.ByteString -> IO BS.ByteString
        checkMagicBytes' chunk@((< magicBytesLength) . BS.length -> True) = do
          next <- read `catchAll` \_ -> throwM (InvalidMagicBytes chunk)
          checkMagicBytes' $ chunk <> next
        checkMagicBytes' (BS.splitAt magicBytesLength -> (bytes, leftovers)) = do
          when (bytes /= magicBytes) $ throwM $ InvalidMagicBytes bytes
          -- Confirm magic bytes
          atomically $ writeTVar multiplexer.receivedHeader True
          pure leftovers

    multiplexerLoop :: Maybe Channel -> StateT BS.ByteString IO a
    multiplexerLoop mChannel = do
      msg <- getMultiplexerMessage
      mNextChannel <- execReceivedMultiplexerMessage mChannel msg
      multiplexerLoop mNextChannel

    lookupChannel :: ChannelId -> IO (Maybe Channel)
    lookupChannel channelId = do
      HM.lookup channelId <$> atomically (readTVar multiplexer.channelsVar)

    runGet :: forall a. Get a -> (forall b. String -> IO b) -> StateT BS.ByteString IO a
    runGet get errorHandler = do
      stateStateM $ liftIO . stepDecoder . pushChunk (runGetIncremental get)
      where
        stepDecoder :: Decoder a -> IO (a, BS.ByteString)
        stepDecoder (Fail _ _ errMsg) = errorHandler errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< read
        stepDecoder (Done leftovers _ msg) = pure (msg, leftovers)

    getMultiplexerMessage :: StateT BS.ByteString IO MultiplexerMessage
    getMultiplexerMessage =
      runGet Binary.get \errMsg ->
        protocolException $ "Failed to parse protocol message: " <> errMsg

    execReceivedMultiplexerMessage :: Maybe Channel -> MultiplexerMessage -> StateT BS.ByteString IO (Maybe Channel)
    execReceivedMultiplexerMessage Nothing (ChannelMessage _ messageLength) = undefined
    execReceivedMultiplexerMessage jc@(Just channel) (ChannelMessage newChannelCount messageLength) = do
      join $ liftIO $ atomically do
        receivedClose <- readTVar channel.receivedCloseMessage
        sentClose <- readTVar channel.sentCloseMessage
        pure do
          -- Receiving messages after the remote side closed a channel is a protocol error
          when receivedClose $ protocolException $
            mconcat ["Received message for invalid channel ", show channel.channelId, " (", show messageLength, " bytes)"]
          if sentClose
            -- Drop received messages when the channel has been closed on the local side
            then undefined -- TODO drop message
            else receiveChannelMessage channel newChannelCount messageLength
          pure jc

    execReceivedMultiplexerMessage _ (SwitchChannel channelId) = liftIO do
      lookupChannel channelId >>= \case
        Nothing -> protocolException $
          mconcat ["Failed to switch to channel ", show channelId, " (invalid id)"]
        Just channel -> do
          receivedClose <- atomically (readTVar channel.receivedCloseMessage)
          when receivedClose $ protocolException $
            mconcat ["Failed to switch to channel ", show channelId, " (channel is closed)"]
          pure (Just channel)

    execReceivedMultiplexerMessage Nothing CloseChannel = undefined
    execReceivedMultiplexerMessage (Just channel) CloseChannel = liftIO do
      traceIO $ "Received close message on channel " <> show channel.channelId
      atomically $ writeTVar channel.receivedCloseMessage True
      sendChannelCloseMessage channel
      disposeEventually_ channel
      when (channel.channelId == 0) do
        -- Signal "clean" exit via exception
        throwM ConnectionClosed
      pure Nothing

    execReceivedMultiplexerMessage _ (MultiplexerProtocolError msg) = throwM $ RemoteException $
      "Remote closed connection because of a multiplexer protocol error: " <> msg
    execReceivedMultiplexerMessage Nothing (ChannelProtocolError msg) = undefined
    execReceivedMultiplexerMessage (Just channel) (ChannelProtocolError msg) =
      throwM $ ChannelProtocolException channel.channelId msg
    execReceivedMultiplexerMessage _ (InternalError msg) =
      throwM $ RemoteException msg

    receiveChannelMessage :: Channel -> NewChannelCount -> MessageLength -> StateT BS.ByteString IO ()
    receiveChannelMessage channel newChannelCount messageLength = do
      modifyStateM \chunk -> liftIO do
        messageId <- atomically $ stateTVar channel.nextReceiveMessageId (\x -> (x, x + 1))
        -- NOTE blocks until a channel handler is set
        handler <- atomically $ maybe retry pure =<< readTVar channel.channelHandler
        messageHandler <- handler ReceivedMessageResources {
          createdChannels = [], -- TODO
          messageId,
          messageLength
        }
        runHandler messageHandler messageLength chunk
      where
        runHandler :: InternalMessageHandler -> MessageLength -> BS.ByteString -> IO BS.ByteString
        -- Signal to handler, that receiving is completed
        runHandler (InternalMessageHandler fn) 0 leftovers = leftovers <$ fn Nothing
        -- Read more data
        runHandler handler remaining (BS.null -> True) = runHandler handler remaining =<< read
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


channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
channelSend = sendChannelMessage

sendChannelMessage :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
sendChannelMessage channel@Channel{multiplexer} configuration payload messageIdHook = liftIO do
  -- To guarantee fairness when sending (and to prevent unnecessary STM retries)
  withMVar multiplexer.outboxGuard \_ -> do

    (messageId, createdChannelIds) <- atomically do
      -- Abort if the multiplexer is finished or currently cleaning up
      mapM_ throwM =<< tryReadAsyncVarSTM multiplexer.multiplexerResult

      -- Prevents message reordering in send thread
      check . null <$> readTVar multiplexer.closeChannelOutbox

      -- Put the message into the outbox. It will be picked up by the send thread.
      putTMVar multiplexer.outbox (channel.channelId, configuration.createChannels, payload)
      messageId <- stateTVar channel.nextSendMessageId (\x -> (x, x + 1))
      messageIdHook messageId

      let createdChannelIds = []
      pure (messageId, createdChannelIds)

    pure $ SentMessageResources {
      messageId,
      createdChannels = []
    }


channelSend_ :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> m SentMessageResources
channelSend_ channel configuration msg = channelSend channel configuration msg (const (pure ()))

channelSendSimple :: MonadIO m => Channel -> BSL.ByteString -> m ()
channelSendSimple channel msg = liftIO do
  -- Pattern match verifies no channels are created due to a bug
  SentMessageResources{createdChannels=[]} <- channelSend channel defaultMessageConfiguration msg (const (pure ()))
  pure ()

channelReportProtocolError :: MonadIO m => Channel -> String -> m b
channelReportProtocolError = undefined

channelReportException :: MonadIO m => Channel -> SomeException -> m b
channelReportException = undefined


channelSetInternalHandler :: MonadIO m => Channel -> InternalHandler -> m ()
channelSetInternalHandler channel handler = liftIO $ atomically $ writeTVar channel.channelHandler (Just handler)

channelSetHandler :: MonadIO m => Channel -> (ReceivedMessageResources -> BSL.ByteString -> ResourceManagerIO ()) -> m ()
channelSetHandler channel fn = channelSetInternalHandler channel bytestringHandler
  where
    bytestringHandler :: ReceivedMessageResources -> IO InternalMessageHandler
    bytestringHandler resources = pure $ InternalMessageHandler $ go []
      where
        go :: [BS.ByteString] -> Maybe BS.ByteString -> IO InternalMessageHandler
        go accum (Just chunk) = pure $ InternalMessageHandler $ go (chunk:accum)
        go accum Nothing =
          InternalMessageHandler (const impossibleCodePathM) <$ do
            enterResourceManager channel.resourceManager do
              fn resources $ BSL.fromChunks (reverse accum)

channelSetSimpleHandler :: MonadIO m => Channel -> (BSL.ByteString -> ResourceManagerIO ()) -> m ()
channelSetSimpleHandler channel fn = channelSetHandler channel \case
  ReceivedMessageResources{createdChannels=[]} -> fn
  _ -> const $ throwM $ ChannelProtocolException channel.channelId "Unexpectedly received new channels"


channelSetImmediateHandler :: MonadIO m => Channel -> ImmediateChannelHandler -> m ()
channelSetImmediateHandler channel handler = undefined -- liftIO $ atomically $ writeTVar channel.channelHandler (Just handler)

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (ReceivedMessageResources -> a -> ResourceManagerIO ()) -> m ()
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
        runHandler result = enterResourceManager channel.resourceManager (fn resources result)

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetSimpleBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (a -> ResourceManagerIO ()) -> m ()
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
