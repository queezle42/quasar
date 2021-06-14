module Network.Rpc.Multiplexer (
  ChannelId,
  MessageId,
  MessageLength,
  Channel,
  MessageHeader(..),
  SentMessageResources(..),
  ReceivedMessageResources(..),
  MultiplexerException,
  channelReportProtocolError,
  channelReportException,
  channelSend,
  channelSend_,
  channelSendSimple,
  channelClose,
  channelSetHandler,
  ChannelMessageHandler,
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Concurrent.Async (async, link, race_, wait, waitAnyCancel, withAsync, withAsyncWithUnmask)
import Control.Exception (Exception(..), Handler(..), MaskingState(Unmasked), SomeException, catch, catches, handle, interruptible, throwIO, getMaskingState, mask_)
import Control.Monad (when, unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (StateT, execStateT, runStateT, lift)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode)
import qualified Data.Binary as Binary
import Data.Binary.Get (Get, Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import Data.Tuple (swap)
import Data.Word
import Network.Rpc.Connection
import Prelude
import GHC.Generics
import System.IO (hPutStrLn, stderr)

-- NOTE this module got more complicated than expected and should be refactored to encode the core protocol interactions in pure code, with an IO wrapper that handles usage, callbacks and sending/receiving.

type ChannelId = Word64
type MessageId = Word64
type MessageLength = Word64
-- | Low level network protocol type
data MultiplexerMessage
  = ChannelMessage [MultiplexerMessageHeader] MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | ProtocolError String
  | ChannelProtocolError ChannelId String
  deriving (Binary, Generic, Show)

-- | Low level network protocol message header type
data MultiplexerMessageHeader = CreateChannel
  deriving (Binary, Generic, Show)

data MessageHeader =
  -- | The callback is running in a masked state and is blocking all network traffic. The callback should only be used to register a callback on the channel and to store it; then it should return immediately.
  CreateChannelHeader

data SentMessageResources = SentMessageResources {
  messageId :: MessageId,
  createdChannels :: [Channel]
}
data ReceivedMessageResources = ReceivedMessageResources {
  messageId :: MessageId,
  createdChannels :: [Channel]
  --unixFds :: Undefined
}

data MultiplexerWorker = MultiplexerWorker {
  stateMVar :: MVar MultiplexerWorkerState,
  multiplexerClosedAtVar :: AtVar MultiplexerException,
  outboxMVar :: MVar (MVar BSL.ByteString)
}
data MultiplexerWorkerState = MultiplexerWorkerState {
  socketConnection :: Either MultiplexerException Connection,
  channels :: HM.HashMap ChannelId Channel,
  sendChannel :: ChannelId,
  receiveChannel :: ChannelId,
  receiveNextChannelId :: ChannelId,
  sendNextChannelId :: ChannelId
}

data MultiplexerException =
  ConnectionClosed
  | ConnectionLost SomeException
  | LocalException SomeException
  | RemoteException String
  | ProtocolException String
  deriving Show
instance Exception MultiplexerException


data Channel = Channel {
  channelId :: ChannelId,
  worker :: MultiplexerWorker,
  stateMVar :: MVar ChannelState,
  sendStateMVar :: MVar ChannelSendState,
  receiveStateMVar :: MVar ChannelReceiveState,
  handlerAtVar :: AtVar InternalChannelMessageHandler
}
data ChannelState = ChannelState {
  connectionState :: ChannelConnectivity,
  children :: [Channel]
}
newtype ChannelSendState = ChannelSendState {
  nextMessageId :: MessageId
}
data ChannelReceiveState = ChannelReceiveState {
  nextMessageId :: MessageId
}

data ChannelConnectivity = Connected | Closed | CloseConfirmed
  deriving (Eq, Show)

data ChannelNotConnected = ChannelNotConnected
  deriving Show
instance Exception ChannelNotConnected

type InternalChannelMessageHandler = ReceivedMessageResources -> Decoder (IO ())

class ChannelMessageHandler a where
  toInternalChannelMessageHandler :: a -> InternalChannelMessageHandler

instance ChannelMessageHandler (ReceivedMessageResources -> Get (IO ())) where
  toInternalChannelMessageHandler fn = runGetIncremental . fn

instance ChannelMessageHandler (ReceivedMessageResources -> BSL.ByteString -> IO ()) where
  toInternalChannelMessageHandler handler result = decoder ""
    where
      decoder :: BSL.ByteString -> Decoder (IO ())
      decoder acc = Partial (maybe done partial)
        where
          partial :: BS.ByteString -> Decoder (IO ())
          partial = decoder . (acc <>) . BSL.fromStrict
          done :: Decoder (IO ())
          done = Done "" (BSL.length acc) (handler result acc)

data MultiplexerSide = MultiplexerSideA | MultiplexerSideB
  deriving (Eq, Show)

-- | Starts a new multiplexer on an existing connection.
-- This starts a thread which runs until 'channelClose' is called on the resulting 'Channel' (use e.g. 'bracket' to ensure the channel is closed).
newMultiplexer :: (IsConnection a) => MultiplexerSide -> a -> IO Channel
newMultiplexer side x = do
  channelMVar <- newEmptyMVar
  -- 'runMultiplexerProtcol' needs to be interruptible (so it can terminate when it is closed), so 'interruptible' is used to ensure that this function also works when used in 'bracket'
  mask_ $ link =<< async (interruptible (runMultiplexer side (putMVar channelMVar) (toSocketConnection x)))
  takeMVar channelMVar

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling 'closeChannel'; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (IsConnection a) => MultiplexerSide -> (Channel -> IO ()) -> a -> IO ()
runMultiplexer side channelSetupHook connection = do
  -- Running in masked state, this thread (running the receive-function) cannot be interrupted when closing the connection
  maskingState <- getMaskingState
  when (maskingState /= Unmasked) (fail "'runMultiplexer' cannot run in masked thread state.")

  stateMVar <- newMVar $ MultiplexerWorkerState {
    socketConnection = Right (toSocketConnection connection),
    channels = HM.empty,
    sendChannel = 0,
    receiveChannel = 0,
    receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
    sendNextChannelId = if side == MultiplexerSideA then 1 else 2
  }
  multiplexerClosedAtVar <- newEmptyAtVar
  let
    worker = MultiplexerWorker {
      stateMVar,
      multiplexerClosedAtVar
    }
    run :: IO MultiplexerException
    run = do
      rootChannel <- withMultiplexerState worker (newChannel worker 0 Connected)
      channelSetupHook rootChannel
      withAsync (receiveThread worker) $ \receiveTask ->
        withAsync (throwIO =<< multiplexerWaitUntilClosed worker) $ \waitForCloseTask -> do
          void $ waitAnyCancel [receiveTask, waitForCloseTask]
      pure ConnectionClosed

  exception <- run `catches` [
    Handler (\(ex :: MultiplexerException) -> pure ex),
    Handler (\(ex :: SomeException) -> pure (LocalException ex))
    ]

  multiplexerClose exception worker >>= \case
    ConnectionClosed -> pure ()
    ex -> throwIO ex

receiveThread :: MultiplexerWorker -> IO a
receiveThread worker = receiveThreadLoop multiplexerDecoder
  where
    multiplexerDecoder :: Decoder MultiplexerMessage
    multiplexerDecoder = runGetIncremental Binary.get
    receiveThreadLoop :: Decoder MultiplexerMessage -> IO a
    receiveThreadLoop (Fail _ _ errMsg) = reportProtocolError worker ("Failed to parse protocol message: " <> errMsg)
    receiveThreadLoop (Partial feedFn) = receiveThreadLoop . feedFn . Just =<< receiveThrowing
    receiveThreadLoop (Done leftovers _ msg) = do
      newLeftovers <- execStateT (handleMultiplexerMessage msg) leftovers
      receiveThreadLoop (pushChunk multiplexerDecoder newLeftovers)
    handleMultiplexerMessage :: MultiplexerMessage -> StateT BS.ByteString IO ()
    handleMultiplexerMessage (ChannelMessage headers len) = do
      workerState <- liftIO $ readMVar worker.stateMVar
      case HM.lookup workerState.receiveChannel workerState.channels of
        Just channel -> handleChannelMessage channel headers len
        Nothing -> liftIO $ reportProtocolError worker ("Received message on invalid channel: " <> show workerState.receiveChannel)
    handleMultiplexerMessage (SwitchChannel channelId) = liftIO $ modifyMVar_ worker.stateMVar $ \state -> pure state{receiveChannel=channelId}
    handleMultiplexerMessage CloseChannel = liftIO $ do
      workerState <- readMVar worker.stateMVar
      case HM.lookup workerState.receiveChannel workerState.channels of
        Just channel -> channelConfirmClose channel
        Nothing -> reportProtocolError worker ("Received CloseChannel on invalid channel: " <> show workerState.receiveChannel)
    handleMultiplexerMessage x = liftIO $ print x >> undefined -- Unhandled multiplexer message

    handleChannelMessage :: Channel -> [MultiplexerMessageHeader] -> MessageLength -> StateT BS.ByteString IO ()
    handleChannelMessage channel headers len = do
      decoder <- liftIO $ do
        messageId <- modifyMVar channel.receiveStateMVar $ \state ->
          pure (state{nextMessageId = state.nextMessageId + 1}, state.nextMessageId)
        let emptyResources = ReceivedMessageResources {
          messageId,
          createdChannels = []
        }
        (messageResources, connectionState) <- withChannelState channel $
          withMultiplexerState2 channel.worker $ do
            messageResources <- execStateT (sequence (processHeader <$> headers)) emptyResources
            -- Don't receive messages on closed channels
            channelState <- State.get
            pure (messageResources, channelState.connectionState)
        case connectionState of
          Connected -> do
            handler :: InternalChannelMessageHandler <- readAtVar channel.handlerAtVar
            pure (handler messageResources)
          -- The channel is closed but the remote might not know that yet, so the message is silently ignored
          Closed -> pure (closedChannelMessageHandler messageResources)
          -- This might only be reached in some edge cases, as a closed channel will be removed from the channel map after the close is confirmed.
          CloseConfirmed -> reportProtocolError worker ("Received message on channel " <> show channel.channelId <> " after receiving a close confirmation for that channel")

      -- StateT currently contains leftovers
      initialLeftovers <- State.get
      let
        leftoversLength = fromIntegral $ BS.length initialLeftovers
        remaining = len - leftoversLength

      (channelCallback, leftovers) <- liftIO $ runDecoder remaining (pushChunk decoder initialLeftovers)

      -- Data is received in chunks but messages have a defined length, so leftovers are put back into StateT
      State.put leftovers
      -- Critical section: don't interrupt downstream callbacks
      liftIO $ mask_ $ withAsyncWithUnmask (\unmask -> unmask channelCallback) wait
      where
        runDecoder :: MessageLength -> Decoder (IO ()) -> IO (IO (), BS.ByteString)
        runDecoder _ (Fail _ _ err) = failedToParseMessage err
        runDecoder 0 (Partial feedFn) = finalizeDecoder "" (feedFn Nothing)
        runDecoder remaining (Partial feedFn) = do
          chunk <- receiveThrowing
          let chunkLength = fromIntegral $ BS.length chunk
          if chunkLength <= remaining
            then runDecoder (remaining - chunkLength) (feedFn (Just chunk))
            else do
              let (partialChunk, leftovers) = BS.splitAt (fromIntegral remaining) chunk
              finalizeDecoder leftovers $ pushEndOfInput $ feedFn $ Just partialChunk
        runDecoder 0 decoder@Done{} = finalizeDecoder "" decoder
        runDecoder _ (Done _ bytesRead _) = failedToConsumeAllInput (fromIntegral bytesRead)
        finalizeDecoder :: BS.ByteString -> Decoder (IO ()) -> IO (IO (), BS.ByteString)
        finalizeDecoder _ (Fail _ _ err) = failedToParseMessage err
        finalizeDecoder _ (Partial _) = failedToTerminate
        finalizeDecoder leftovers (Done "" _ result) = pure (result, leftovers)
        finalizeDecoder _ (Done _ bytesRead _) = failedToConsumeAllInput (fromIntegral bytesRead)
        failedToParseMessage :: String -> IO a
        failedToParseMessage err = channelReportProtocolError channel ("Failed to parse message: " <> err)
        failedToConsumeAllInput :: MessageLength -> IO a
        failedToConsumeAllInput bytesRead = channelReportProtocolError channel ("Decoder failed to consume complete message (" <> show (len - bytesRead) <> " bytes left)")
        failedToTerminate :: IO a
        failedToTerminate = undefined -- channelReportException channel "Decoder failed to terminate after end-of-input"
        processHeader :: MultiplexerMessageHeader -> StateT ReceivedMessageResources (StateT ChannelState (StateT MultiplexerWorkerState IO)) ()
        processHeader CreateChannel = do
          channelId <- lift $ lift $ State.state $ \workerState ->
            (workerState.receiveNextChannelId, workerState{receiveNextChannelId = workerState.receiveNextChannelId + 2})
          createdChannel <- lift $ do
            createdChannel <- newSubChannel channel.worker channelId
            State.modify $ \channelState -> channelState{
                children = createdChannel : channelState.children
            }
            pure createdChannel
          State.modify $ \resources -> resources{createdChannels = resources.createdChannels <> [createdChannel]}
    receiveThrowing :: IO BS.ByteString
    receiveThrowing = do
      state <- readMVar worker.stateMVar
      either throwIO (.receive) state.socketConnection


closedChannelMessageHandler :: ReceivedMessageResources -> Decoder (IO ())
closedChannelMessageHandler result = discardMessageDecoder closeSubChannels
  where
    closeSubChannels :: IO ()
    closeSubChannels = mapM_ closeSubChannel result.createdChannels
    closeSubChannel :: Channel -> IO ()
    closeSubChannel createdChannel =
      -- The channel that received the message is already closed, so newly created children are implicitly closed as well
      modifyMVar_ createdChannel.stateMVar $ \state ->
        pure state{connectionState = Closed}

    discardMessageDecoder :: IO () -> Decoder (IO ())
    discardMessageDecoder action = Partial (maybe done partial)
      where
        partial :: BS.ByteString -> Decoder (IO ())
        partial = const (discardMessageDecoder action)
        done :: Decoder (IO ())
        done = Done "" 0 action

withMultiplexerState :: MultiplexerWorker -> StateT MultiplexerWorkerState IO a -> IO a
withMultiplexerState worker action = modifyMVar worker.stateMVar $ fmap swap . runStateT action

withMultiplexerState2 :: MultiplexerWorker -> StateT ChannelState (StateT MultiplexerWorkerState IO) a -> StateT ChannelState IO a
withMultiplexerState2 worker action = do
  channelState <- State.get
  (result, newChannelState) <- liftIO $ modifyMVar worker.stateMVar $
    fmap swap . runStateT (runStateT action channelState)
  State.put newChannelState
  pure result

withChannelState :: Channel -> StateT ChannelState IO a -> IO a
withChannelState channel action = modifyMVar channel.stateMVar $ fmap swap . runStateT action

multiplexerSend :: MultiplexerWorker -> MultiplexerMessage -> IO ()
multiplexerSend worker msg = withMultiplexerState worker (multiplexerStateSend worker msg)

multiplexerStateSend :: MultiplexerWorker -> MultiplexerMessage -> StateT MultiplexerWorkerState IO ()
multiplexerStateSend worker = multiplexerStateSendRaw worker . encode

multiplexerStateSendRaw :: MultiplexerWorker -> BSL.ByteString -> StateT MultiplexerWorkerState IO ()
multiplexerStateSendRaw worker rawMsg = do
  state <- State.get
  case state.socketConnection of
    Left ex -> liftIO $ throwIO ex
    -- TODO catch
    Right connection -> liftIO $
      race_
        (throwIO =<< multiplexerWaitUntilClosed worker)
        (connection.send rawMsg `catch` \ex -> throwIO =<< multiplexerClose (ConnectionLost ex) worker)

channelSend :: Channel -> [MessageHeader] -> BSL.ByteString -> (MessageId -> IO ()) -> IO SentMessageResources
channelSend channel headers msg callback = do
  modifyMVar channel.sendStateMVar $ \channelSendState -> do
    -- Don't send on closed channels
    withChannelState channel $ do
      channelState <- State.get

      liftIO $ do
        unless (channelState.connectionState == Connected) $ throwIO ChannelNotConnected
        callback channelSendState.nextMessageId

      let emptyResources = SentMessageResources {
        messageId = channelSendState.nextMessageId,
        createdChannels = []
      }

      -- Sending a channel message consists of multiple low-level send operations, so the MVar is held during the operation
      withMultiplexerState2 worker $ do
        lift $ multiplexerSwitchChannel worker channel.channelId

        -- TODO make sure we are deadlock-free before taking the channel state (if the receiver takes the multiplexer state and then the channel state that's a deadlock)
        (headerMessages, resources) <- runStateT (sequence (prepareHeader <$> headers)) emptyResources

        lift $ do
          multiplexerStateSend worker (ChannelMessage headerMessages (fromIntegral (BSL.length msg)))
          multiplexerStateSendRaw worker msg

        pure (channelSendState{nextMessageId = channelSendState.nextMessageId + 1}, resources)
  where
    worker :: MultiplexerWorker
    worker = channel.worker
    prepareHeader :: MessageHeader -> StateT SentMessageResources (StateT ChannelState (StateT MultiplexerWorkerState IO)) MultiplexerMessageHeader
    prepareHeader CreateChannelHeader = do
      nextChannelId <- lift $ lift $ State.state (\multiplexerState -> (multiplexerState.sendNextChannelId, multiplexerState{sendNextChannelId = multiplexerState.sendNextChannelId + 2}))
      createdChannel <- lift $ newSubChannel worker nextChannelId

      State.modify $ \resources -> resources{createdChannels = resources.createdChannels <> [createdChannel]}
      pure CreateChannel

channelSend_ :: Channel -> [MessageHeader] -> BSL.ByteString -> IO SentMessageResources
channelSend_ channel headers msg = channelSend channel headers msg (const (pure ()))

channelSendSimple :: Channel -> BSL.ByteString -> IO ()
channelSendSimple channel msg = do
  -- We are not sending headers, so no channels can be created
  SentMessageResources{createdChannels=[]} <- channelSend channel [] msg (const (pure ()))
  pure ()

multiplexerSwitchChannel :: MultiplexerWorker -> ChannelId -> StateT MultiplexerWorkerState IO ()
multiplexerSwitchChannel worker channelId = do
  -- Check if channel switch is required and update current channel
  shouldSwitchChannel <- State.state (\state -> (state.sendChannel /= channelId, state{sendChannel = channelId}))
  when shouldSwitchChannel $ multiplexerStateSend worker (SwitchChannel channelId)

-- | Closes a channel and all it's children: After the function completes, the channel callback will no longer be called on received messages and sending messages on the channel will fail.
-- Calling close on a closed channel is a noop.
channelClose :: Channel -> IO ()
channelClose channel = do
  -- Change channel state of all unclosed channels in the tree to closed
  channelWasClosed <- channelClose' channel

  when channelWasClosed $
    -- Closing a channel on a Connection that is no longer connected should not throw an exception (channelClose is a resource management operation and is supposed to be idempotent)
    handle (\(_ :: MultiplexerException) -> pure ()) $ do
      -- Send close message
      withMultiplexerState worker $ do
        multiplexerSwitchChannel worker channel.channelId
        multiplexerStateSend worker CloseChannel

      -- Terminate the worker when the root channel is closed
      when (channel.channelId == 0) $ multiplexerClose_ ConnectionClosed worker
  where
    worker = channel.worker
    channelClose' :: Channel -> IO Bool
    channelClose' chan = modifyMVar chan.stateMVar $ \state ->
      case state.connectionState of
        Connected -> do
          -- Close all children while blocking the state. This prevents children from receiving a messages after the parent channel has already rejected a message
          liftIO (mapM_ channelClose' state.children)
          pure (state{connectionState = Closed}, True)
        -- Channel was already closed and can be ignored
        Closed -> pure (state, False)
        CloseConfirmed -> pure (state, False)

multiplexerWaitUntilClosed :: MultiplexerWorker -> IO MultiplexerException
multiplexerWaitUntilClosed worker = readAtVar worker.multiplexerClosedAtVar

-- Called on a channel when a ChannelClose message is received
channelConfirmClose :: Channel -> IO ()
channelConfirmClose channel = do
  closeConfirmedIds <- channelClose' channel

  -- List can only be empty when the channel was already confirmed as closed
  unless (null closeConfirmedIds) $ do
    -- Remote channels from worker
    withMultiplexerState channel.worker $ do
      State.modify $ \state -> state{channels = foldr HM.delete state.channels closeConfirmedIds}

    -- Terminate the worker when the root channel is closed
    when (channel.channelId == 0) $ multiplexerClose_ ConnectionClosed channel.worker
  where
    channelClose' :: Channel -> IO [ChannelId]
    channelClose' chan = modifyMVar chan.stateMVar $ \state ->
      case state.connectionState of
        Connected -> do
          closedIdLists <- liftIO (mapM channelClose' state.children)
          let
            closedIds = chan.channelId : mconcat closedIdLists
            newState = state{connectionState = CloseConfirmed}
          pure (newState, closedIds)
        Closed -> do
          closedIdLists <- liftIO (mapM channelClose' state.children)
          let
            closedIds = chan.channelId : mconcat closedIdLists
            newState = state{connectionState = CloseConfirmed}
          pure (newState, closedIds)
        -- Ignore already closed children
        CloseConfirmed -> pure (state, [])

multiplexerClose :: MultiplexerException -> MultiplexerWorker -> IO MultiplexerException
multiplexerClose exception worker = mask_ $ do
  (actualException, mConnection) <- withMultiplexerState worker $ State.state $ \state ->
    case state.socketConnection of
      Left ex -> ((ex, Nothing), state)
      Right connection -> ((exception, Just connection), state{socketConnection = Left exception})
  mapM_ (.close) mConnection
  -- Stop sender and receiver thread
  writeAtVar worker.multiplexerClosedAtVar exception
  pure actualException

multiplexerClose_ :: MultiplexerException -> MultiplexerWorker -> IO ()
multiplexerClose_ exception worker = void $ multiplexerClose exception worker

reportProtocolError :: MultiplexerWorker -> String -> IO b
reportProtocolError worker message = do
  multiplexerSend worker $ ProtocolError message
  let ex = ProtocolException message
  multiplexerClose_ ex worker
  throwIO ex

channelReportProtocolError :: Channel -> String -> IO b
channelReportProtocolError channel message = do
  -- TODO: send channelId as well
  multiplexerSend channel.worker $ ChannelProtocolError channel.channelId message
  let ex = ProtocolException message
  multiplexerClose_ ex channel.worker
  throwIO ex

channelReportException :: Channel -> SomeException -> IO b
channelReportException channel exception = do
  hPutStrLn stderr $ "Local error on channel " <> show channel.channelId <> ": " <> displayException exception
  multiplexerSend channel.worker $ ProtocolError $ "Internal server error on channel " <> show channel.channelId
  let ex = LocalException exception
  multiplexerClose_ ex channel.worker
  throwIO ex

-- The StateT holds the parent channels state
newSubChannel :: MultiplexerWorker -> ChannelId -> (StateT ChannelState (StateT MultiplexerWorkerState IO)) Channel
newSubChannel worker channelId = do
  parentChannelState <- State.get
  -- Holding the parents channelState while initializing the channel will ensure the ChannelConnectivity is inherited atomically
  createdChannel <- lift $ newChannel worker channelId parentChannelState.connectionState

  let newParentState = parentChannelState{
    children = createdChannel : parentChannelState.children
  }
  State.put newParentState
  pure createdChannel

newChannel :: MultiplexerWorker -> ChannelId -> ChannelConnectivity -> StateT MultiplexerWorkerState IO Channel
newChannel worker channelId connectionState = do
  stateMVar <- liftIO $ newMVar ChannelState {
    connectionState,
    children = []
  }
  sendStateMVar <- liftIO $ newMVar ChannelSendState {
    nextMessageId = 0
  }
  receiveStateMVar <- liftIO $ newMVar ChannelReceiveState {
    nextMessageId = 0
  }
  handlerAtVar <- liftIO newEmptyAtVar
  let channel = Channel {
    worker,
    channelId,
    stateMVar,
    sendStateMVar,
    receiveStateMVar,
    handlerAtVar
  }
  State.modify $ \multiplexerState -> multiplexerState{channels = HM.insert channelId channel multiplexerState.channels}
  pure channel

channelSetHandler :: ChannelMessageHandler a => Channel -> a -> IO ()
channelSetHandler channel = writeAtVar channel.handlerAtVar . toInternalChannelMessageHandler

-- | Helper for an atomically writable MVar that can also be empty and, when read, will block until it has a value.
data AtVar a = AtVar (MVar a) (MVar AtVarState)
data AtVarState = AtVarIsEmpty | AtVarHasValue

newEmptyAtVar :: IO (AtVar a)
newEmptyAtVar = do
  valueMVar <- newEmptyMVar
  guardMVar <- newMVar AtVarIsEmpty
  pure $ AtVar valueMVar guardMVar

writeAtVar :: AtVar a -> a -> IO ()
writeAtVar (AtVar valueMVar guardMVar) value = modifyMVar_ guardMVar $ \case
  AtVarIsEmpty -> putMVar valueMVar value >> pure AtVarHasValue
  AtVarHasValue -> modifyMVar_ valueMVar (const (pure value)) >> pure AtVarHasValue

readAtVar :: AtVar a -> IO a
readAtVar (AtVar valueMVar _) = readMVar valueMVar
