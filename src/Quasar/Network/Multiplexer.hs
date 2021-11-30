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
  sendChannelMessage,
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
import Data.Void (vacuous)
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
  deriving anyclass Binary


-- ** Multiplexer

data Multiplexer = Multiplexer {
  side :: MultiplexerSide,
  disposable :: Disposable,
  multiplexerException :: AsyncVar MultiplexerException,
  multiplexerResult :: AsyncVar (Maybe MultiplexerException),
  receiveThreadCompleted :: Awaitable (),
  receivedHeader :: TVar Bool,
  outbox :: TMVar (ChannelId, NewChannelCount, BSL.ByteString),
  outboxGuard :: MVar (),
  -- Set to true after magic bytes have been received
  closeChannelOutbox :: TVar [ChannelId],
  channelsVar :: TVar (HM.HashMap ChannelId Channel),
  nextReceiveChannelId :: TVar ChannelId,
  nextSendChannelId :: TVar ChannelId
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
  | CloseTimeoutReached -- "Multiplexer reached timeout while gracefully closing connection"
  deriving stock Show

protocolException :: MonadThrow m => String -> m a
protocolException = throwM . ProtocolException

-- ** Channel

data Channel = Channel {
  multiplexer :: Multiplexer,
  resourceManager :: ResourceManager,
  channelId :: ChannelId,
  channelHandler :: TVar (Maybe InternalHandler),
  parent :: Maybe Channel,
  children :: TVar (HM.HashMap ChannelId Channel),
  nextSendMessageId :: TVar MessageId,
  nextReceiveMessageId :: TVar MessageId,
  receivedCloseMessage :: TVar Bool,
  sentCloseMessage :: TVar Bool
}

instance IsDisposable Channel where
  toDisposable channel = toDisposable channel.resourceManager

instance IsResourceManager Channel where
  toResourceManager channel = channel.resourceManager

newRootChannel :: Multiplexer -> ResourceManagerIO Channel
newRootChannel multiplexer = do
  resourceManager <- askResourceManager
  liftIO do
    channelHandler <- newTVarIO Nothing
    children <- newTVarIO mempty
    nextSendMessageId <- newTVarIO 0
    nextReceiveMessageId <- newTVarIO 0
    receivedCloseMessage <- newTVarIO False
    sentCloseMessage <- newTVarIO False

    let channel = Channel {
      multiplexer,
      resourceManager,
      channelId = 0,
      channelHandler,
      parent = Nothing,
      children,
      nextSendMessageId,
      nextReceiveMessageId,
      receivedCloseMessage,
      sentCloseMessage
    }

    attachDisposeAction_ resourceManager $ atomically $ sendChannelCloseMessage channel

    pure channel

newChannelSTM :: Channel -> ChannelId -> STM Channel
newChannelSTM parent@Channel{multiplexer, resourceManager=parentResourceManager} channelId = do
  -- Channels inherit their parents close state
  parentReceivedCloseMessage <- readTVar parent.receivedCloseMessage
  parentSentCloseMessage <- readTVar parent.sentCloseMessage

  resourceManager <- newResourceManagerSTM parentResourceManager
  channelHandler <- newTVar Nothing
  children <- newTVar mempty
  nextSendMessageId <- newTVar 0
  nextReceiveMessageId <- newTVar 0
  receivedCloseMessage <- newTVar parentReceivedCloseMessage
  sentCloseMessage <- newTVar parentSentCloseMessage

  let channel = Channel {
    multiplexer,
    resourceManager,
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

  disposable <- newSTMDisposable $ sendChannelCloseMessage channel
  attachDisposableSTM resourceManager disposable

  modifyTVar multiplexer.channelsVar $ HM.insert channelId channel

  pure channel

sendChannelCloseMessage :: Channel -> STM ()
sendChannelCloseMessage channel = do
  unlessM (readTVar channel.sentCloseMessage) do
    modifyTVar channel.multiplexer.closeChannelOutbox (channel.channelId :)
    -- Mark as closed and propagate close state to children
    markAsClosed channel
    cleanupChannel channel
  where
    markAsClosed :: Channel -> STM ()
    markAsClosed channel = do
      writeTVar channel.sentCloseMessage True
      children <- readTVar channel.children
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

type ImmediateChannelHandler = ReceivedMessageResources -> ResourceManagerIO (BS.ByteString -> IO (), ResourceManagerIO ())

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
runMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> (Channel -> ResourceManagerIO ()) -> a -> m ()
runMultiplexer side channelSetupHook (toSocketConnection -> connection) = liftResourceManagerIO $ mask_ do
  (rootChannel, result) <- newMultiplexerInternal side connection
  onResourceManager rootChannel $ channelSetupHook rootChannel
  mException <- await result
  mapM_ throwM mException

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> a -> m Channel
newMultiplexer side (toSocketConnection -> connection) = liftResourceManagerIO $ mask_ do
  resourceManager <- askResourceManager
  (rootChannel, result) <- newMultiplexerInternal side connection
  async_ $ liftIO $ uninterruptibleMask_ do
    mException <- await result
    mapM_ (throwToResourceManager resourceManager) mException
  pure rootChannel

newMultiplexerInternal :: MultiplexerSide -> Connection -> ResourceManagerIO (Channel, Awaitable (Maybe MultiplexerException))
newMultiplexerInternal side connection = disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by `disposeOnError`, so it can be used as a disposable
  -- without accidentally disposing external resources.
  resourceManager <- askResourceManager

  outbox <- liftIO $ newEmptyTMVarIO
  multiplexerException <- newAsyncVar
  multiplexerResult <- newAsyncVar
  outboxGuard <- liftIO $ newMVar ()
  receivedHeader <- liftIO $ newTVarIO False
  closeChannelOutbox <- liftIO $ newTVarIO mempty
  nextReceiveChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 2 else 1
  nextSendChannelId <- liftIO $ newTVarIO $ if side == MultiplexerSideA then 1 else 2

  rootChannel <- mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    lockResourceManager do
      multiplexer <- mfix \multiplexer -> do
        receiveThread <- unmanagedAsyncWithHandler (multiplexerExceptionHandler multiplexer) do
          liftIO $ receiveThread multiplexer connection.receive
        sendThread <- unmanagedAsyncWithHandler (multiplexerExceptionHandler multiplexer) do
          liftIO $ sendThread multiplexer connection.send
        let
          sendThreadCompleted = awaitSuccessOrFailure sendThread
          receiveThreadCompleted = awaitSuccessOrFailure receiveThread

        registerAsyncDisposeAction do
          -- NOTE The network connection should be closed automatically when the root channel is closed.
          -- This action exists to ensure the network connection is not blocking a resource manager for an unbounded
          -- amount of time while having enough time to perform a graceful close.

          timeout <- newUnmanagedDelay 2000000

          -- Valid reasons to abort the multiplexer threads:
          r <- awaitEither
            -- Timeout reached
            (await timeout)
            -- Send *and* receive thread have terminated on their own, which happens after final messages (i.e. root
            -- channel closed or error messages) have been exchanged.
            (sendThreadCompleted >> receiveThreadCompleted)

          -- Timeout reached
          when (r == Left ()) do
            putAsyncVar_ multiplexerException $ ConnectionLost CloseTimeoutReached

          dispose sendThread
          dispose receiveThread
          connection.close

          putAsyncVar_ multiplexerResult =<< peekAwaitable multiplexerException

        pure Multiplexer {
          side,
          disposable = toDisposable resourceManager,
          multiplexerException,
          multiplexerResult,
          receiveThreadCompleted,
          outbox,
          outboxGuard,
          receivedHeader,
          closeChannelOutbox,
          channelsVar,
          nextReceiveChannelId,
          nextSendChannelId
        }

      newRootChannel multiplexer

  pure (rootChannel, toAwaitable multiplexerResult)


multiplexerExceptionHandler :: Multiplexer -> SomeException -> IO ()
multiplexerExceptionHandler multiplexer (toMultiplexerException -> ex) = do
  unlessM (putAsyncVar multiplexer.multiplexerException ex) do
    traceIO $ "Multiplexer ignored exception: " <> displayException ex
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
awaitConnectionLost :: Multiplexer -> Awaitable ()
awaitConnectionLost multiplexer =
  unsafeAwaitSTM do
    r <- readAsyncVarSTM multiplexer.multiplexerException
    check (isConnectionLost r)
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
    sendLoop :: StateT ChannelId IO ()
    sendLoop = do
      join $ liftIO $ atomically do
        tryReadAsyncVarSTM multiplexer.multiplexerException >>= \case
          -- Send exception (if required for that exception type) and then terminate send loop
          Just fatalException -> pure $ sendException fatalException
          Nothing -> do
            mMessage <- tryTakeTMVar multiplexer.outbox
            closeChannelQueue <- swapTVar multiplexer.closeChannelOutbox []
            case (mMessage, closeChannelQueue) of
              -- Exit when the receive thread has stopped and there is no error and no message left to send
              (Nothing, []) -> pure () <$ await multiplexer.receiveThreadCompleted
              _ -> pure do
                msg <- execWriterT do
                  formatChannelMessage mMessage
                  -- closeChannelQueue is used as a queue, so it has to be reversed to keep the order of close messages
                  formatCloseMessages (reverse closeChannelQueue)
                liftIO $ send msg
                sendLoop
    send :: MonadIO m => Put -> m ()
    send chunks = liftIO $ sendFn (Binary.runPut chunks) `catchAll` (throwM . ConnectionLost . SendFailed)
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


-- | Internal state of the `receiveThread` function.
type ReceiveThreadState = Maybe Channel

receiveThread :: Multiplexer -> IO BS.ByteString -> IO ()
receiveThread multiplexer readFn = do
  rootChannel <- lookupChannel 0
  chunk <- case multiplexer.side of
    MultiplexerSideA -> read
    MultiplexerSideB -> checkMagicBytes
  evalStateT (multiplexerLoop rootChannel) chunk
  where
    read :: IO BS.ByteString
    read = readFn `catchAll` \ex -> throwM $ ConnectionLost $ ReceiveFailed ex

    -- | Reads and verifies magic bytes. Returns bytes left over from the received chunk(s).
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

    multiplexerLoop :: ReceiveThreadState -> StateT BS.ByteString IO ()
    multiplexerLoop prevState = do
      msg <- getMultiplexerMessage
      mNextState <- execReceivedMultiplexerMessage prevState msg
      mapM_ multiplexerLoop mNextState

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

    execReceivedMultiplexerMessage :: ReceiveThreadState -> MultiplexerMessage -> StateT BS.ByteString IO (Maybe ReceiveThreadState)
    execReceivedMultiplexerMessage Nothing (ChannelMessage _ messageLength) = undefined
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
          receivedClose <- atomically (readTVar channel.receivedCloseMessage)
          when receivedClose $ protocolException $
            mconcat ["Failed to switch to channel ", show channelId, " (channel is closed)"]
          pure (Just (Just channel))

    execReceivedMultiplexerMessage Nothing CloseChannel = undefined
    execReceivedMultiplexerMessage (Just channel) CloseChannel = liftIO do
      atomically do
        setReceivedChannelCloseMessage channel
        sendChannelCloseMessage channel
      disposeEventually_ channel
      pure if channel.channelId /= 0
        then Just Nothing
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

    dropBytes :: MessageLength -> StateT BS.ByteString IO ()
    dropBytes = modifyStateM . go
      where
        go :: MessageLength -> BS.ByteString -> IO BS.ByteString
        go remaining chunk
          | chunkLength <= remaining = do
            go (remaining - chunkLength) =<< read
          | otherwise = do
            pure $ BS.drop (fromIntegral remaining) chunk
          where
            chunkLength = fromIntegral $ BS.length chunk


channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
channelSend = sendChannelMessage
{-# DEPRECATED channelSend "Use sendChannelMessage instead" #-}

sendChannelMessage :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> STM ()) -> m SentMessageResources
sendChannelMessage channel@Channel{multiplexer} MessageConfiguration{closeChannel, createChannels} payload messageIdHook =
  -- Ensure resources are disposed (if the channel is closed)
  liftIO $ mask_ do

    -- Locking the 'outboxGuard' guarantees fairness when sending messages concurrently (it also prevents unnecessary
    -- STM retries)
    result <- withMVar multiplexer.outboxGuard \_ -> do
      atomically do
        -- Abort if the multiplexer is finished or currently cleaning up
        mapM_ throwM =<< tryReadAsyncVarSTM multiplexer.multiplexerException

        -- Abort if the channel is closed
        verifyChannelIsConnected channel

        -- Block until all previously queued close messages have been sent.
        -- This prevents message reordering in the send thread.
        check . null <$> readTVar multiplexer.closeChannelOutbox

        -- Put the message into the outbox. It will be picked up by the send thread.
        -- Retries (blocks) until the outbox is available.
        putTMVar multiplexer.outbox (channel.channelId, createChannels, payload)
        messageId <- stateTVar channel.nextSendMessageId (\x -> (x, x + 1))
        messageIdHook messageId

        when closeChannel $ sendChannelCloseMessage channel

        createdChannelIds <- stateTVar multiplexer.nextSendChannelId (createChannelIds createChannels)
        createdChannels <- mapM (newChannelSTM channel) createdChannelIds

        pure SentMessageResources {
          messageId,
          createdChannels
        }

    when closeChannel do
      disposeEventually_ channel

    pure result

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
