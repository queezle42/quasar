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


import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.DeepSeq (rnf)
import Control.Monad.Catch
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.State qualified as State
import Data.Bifunctor (first)
import Data.Binary (Binary, Put)
import Data.Binary qualified as Binary
import Data.Binary.Get (Get, Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import Data.Binary.Put qualified as Binary
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Connection
import Quasar.Prelude
import Quasar.ResourceManager
import System.IO (hPutStrLn, stderr)

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
  | ChannelProtocolError ChannelId String
  | InternalError String
  deriving stock (Generic, Show)
  deriving anyclass (Binary)


-- ** Multiplexer

data Multiplexer = Multiplexer {
  disposable :: Disposable,
  inbox :: TMVar (BS.ByteString),
  outbox :: TMVar (ChannelId, NewChannelCount, BSL.ByteString),
  outboxGuard :: MVar (),
  closeChannelOutbox :: TVar [ChannelId],
  channelsVar :: TVar (HM.HashMap ChannelId Channel),
  multiplexerResult :: AsyncVar MultiplexerException
}
instance IsDisposable Multiplexer where
  toDisposable = (.disposable)

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

    pure Channel {
      multiplexer,
      resourceManager,
      channelId,
      channelHandler,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

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
runMultiplexer side channelSetupHook (toSocketConnection -> connection) = liftResourceManagerIO do
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
  closeChannelOutbox <- liftIO $ newTVarIO mempty

  registerDisposeAction do
    -- Setting `ConnectionClosed` before calling `close` suppresses exceptions from
    -- the send- and receive thread (which occur after closing the socket)
    putAsyncVar_ multiplexerResult ConnectionClosed
    connection.close

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    --sendChannel = 0,
    --receiveChannel = 0,
    --receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
    --sendNextChannelId = if side == MultiplexerSideA then 1 else 2
    let multiplexer = Multiplexer {
      disposable = toDisposable resourceManager,
      inbox,
      outbox,
      outboxGuard,
      closeChannelOutbox,
      channelsVar,
      multiplexerResult
    }

    handleAsync_ (multiplexerCloseWithException multiplexer . ConnectionLost) (liftIO (receiveThread inbox))
    handleAsync_ (multiplexerExceptionHandler multiplexer) (liftIO (sendThread multiplexer))
    handleAsync_ (multiplexerExceptionHandler multiplexer) (liftIO (multiplexerThread multiplexer))

    async_ do
      await $ isDisposed rootChannel
      -- Ensure the multiplexer is disposed when the last channel is closed
      disposeEventually_ resourceManager

    newChannel multiplexer 0

  pure (rootChannel, toAwaitable multiplexerResult)
  where
    receiveThread :: TMVar BS.ByteString -> IO ()
    receiveThread inbox = forever do
      chunk <- connection.receive
      atomically $ putTMVar inbox chunk

    sendThread :: Multiplexer -> IO ()
    sendThread multiplexer = do
      send $ Binary.putByteString magicBytes
      evalStateT sendLoop 0
      where
        sendLoop :: StateT ChannelId IO ()
        sendLoop = do
          join $ liftIO $ atomically do
            tryReadAsyncVarSTM multiplexer.multiplexerResult >>= \case
              Just fatalException -> pure $ liftIO $ sendException fatalException
              Nothing -> do
                mMessage <- tryTakeTMVar multiplexer.outbox
                closeChannelList <- swapTVar multiplexer.closeChannelOutbox []
                case (mMessage, closeChannelList) of
                  (Nothing, []) -> retry
                  _ -> pure ()
                pure do
                  x <- formatChannelMessage mMessage
                  y <- formatCloseMessages closeChannelList
                  liftIO $ send $ x <> y
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
        formatChannelMessage :: Maybe (ChannelId, NewChannelCount, BSL.ByteString) -> StateT ChannelId IO Put
        formatChannelMessage Nothing = pure mempty
        formatChannelMessage (Just (channelId, newChannelCount, message)) = do
          let
            messageLength = fromIntegral $ BSL.length message
            messagePayload = Binary.put (ChannelMessage newChannelCount messageLength) >> Binary.putLazyByteString message
          liftA2 (<>) (switchToChannel channelId) (pure messagePayload)
        formatCloseMessages :: [ChannelId] -> StateT ChannelId IO Put
        formatCloseMessages [] = pure mempty
        formatCloseMessages _ = undefined
        switchToChannel :: ChannelId -> StateT ChannelId IO Put
        switchToChannel channelId = do
          currentChannelId <- State.get
          if (channelId == currentChannelId)
            then pure mempty
            else do
              State.put channelId
              pure $ Binary.put $ SwitchChannel channelId


multiplexerExceptionHandler :: Multiplexer -> SomeException -> IO ()
-- Exception is a MultiplexerException already
multiplexerExceptionHandler m (fromException -> Just ex) = multiplexerCloseWithException m ex
-- Exception is an unexpected exception
multiplexerExceptionHandler m ex = multiplexerCloseWithException m $ LocalException ex

multiplexerCloseWithException :: Multiplexer -> MultiplexerException -> IO ()
multiplexerCloseWithException m ex = do
  putAsyncVar_ m.multiplexerResult ex
  disposeEventually_ m

multiplexerThread :: Multiplexer -> IO ()
multiplexerThread multiplexer = checkMagicBytes =<< read
  where
    read :: IO BS.ByteString
    read = atomically $ takeTMVar multiplexer.inbox

    continueWithMoreData :: (BS.ByteString -> IO ()) -> BS.ByteString -> IO ()
    continueWithMoreData messageHandler leftovers = messageHandler . (leftovers <>) =<< read

    checkMagicBytes :: BS.ByteString -> IO ()
    checkMagicBytes chunk@((< magicBytesLength) . BS.length -> True) =
      continueWithMoreData checkMagicBytes chunk
    checkMagicBytes (BS.splitAt magicBytesLength -> (bytes, leftovers)) =
      if bytes == magicBytes
        then switchToChannel 0 leftovers
        else throwM $ InvalidMagicBytes $ bytes

    magicBytesLength = BS.length magicBytes

    switchToChannel :: ChannelId -> BS.ByteString -> IO ()
    switchToChannel channelId leftovers = do
      HM.lookup channelId <$> atomically (readTVar multiplexer.channelsVar) >>= \case
        Nothing -> throwM $ ProtocolException $ "Failed to switch to invalid channel " <> show channelId
        Just rootChannel -> nextMultiplexerMessage rootChannel leftovers

    nextMultiplexerMessage :: Channel -> BS.ByteString -> IO ()
    nextMultiplexerMessage channel leftovers = stepDecoder (pushChunk (runGetIncremental Binary.get) leftovers)
      where
        stepDecoder :: Decoder MultiplexerMessage -> IO ()
        stepDecoder (Fail _ _ errMsg) = throwM $ ProtocolException $ "Failed to parse protocol message: " <> errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< (read)
        stepDecoder (Done leftovers _ msg) = execMultiplexerMessage channel msg leftovers

    execMultiplexerMessage :: Channel -> MultiplexerMessage -> BS.ByteString -> IO ()
    execMultiplexerMessage channel multiplexerMessage leftovers =
      case multiplexerMessage of
        (ChannelMessage newChannelCount messageLength) -> receiveChannelMessage channel newChannelCount messageLength leftovers
        (SwitchChannel channelId) -> switchToChannel channelId leftovers
        CloseChannel -> undefined
        (MultiplexerProtocolError msg) -> throwM $ RemoteException $ "Remote closed connection because of a multiplexer protocol error: " <> msg
        (ChannelProtocolError channelId msg) -> throwM $ ChannelProtocolException channelId msg
        (InternalError msg) -> throwM $ RemoteException msg
      where
        continue = nextMultiplexerMessage channel leftovers

    receiveChannelMessage :: Channel -> NewChannelCount -> MessageLength -> BS.ByteString -> IO ()
    receiveChannelMessage channel newChannelCount messageLength chunk = do
      messageId <- atomically $ stateTVar channel.nextReceiveMessageId (\x -> (x, x + 1))
      handler <- atomically $ maybe retry pure =<< readTVar channel.channelHandler
      messageHandler <- handler ReceivedMessageResources {
        createdChannels = [], -- TODO
        messageId,
        messageLength
      }
      runHandler messageHandler messageLength chunk
      where
        runHandler :: InternalMessageHandler -> MessageLength -> BS.ByteString -> IO ()
        runHandler (InternalMessageHandler fn) 0 leftovers = do
          void $ fn Nothing
          nextMultiplexerMessage channel leftovers
        runHandler handler remaining (BS.null -> True) = runHandler handler remaining =<< read
        runHandler (InternalMessageHandler fn) remaining chunk
          | chunkLength <= remaining = do
            next <- fn (Just chunk)
            runHandler next (remaining - chunkLength) ""
          | otherwise = do
            let (partialChunk, leftovers) = BS.splitAt (fromIntegral remaining) chunk
            next <- fn (Just partialChunk)
            runHandler next 0 leftovers
          where
            chunkLength = fromIntegral $ BS.length chunk


channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
channelSend channel@Channel{multiplexer} configuration payload messageIdHook = liftIO do
  -- To guarantee fairness when sending (and to prevent unnecessary STM retries)
  withMVar multiplexer.outboxGuard \_ ->
    atomically do
      mapM_ throwM =<< tryReadAsyncVarSTM multiplexer.multiplexerResult
      check . null <$> readTVar multiplexer.closeChannelOutbox
      putTMVar multiplexer.outbox (channel.channelId, configuration.createChannels, payload)
      messageId <- stateTVar channel.nextSendMessageId (\x -> (x, x + 1))
      messageIdHook messageId
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
