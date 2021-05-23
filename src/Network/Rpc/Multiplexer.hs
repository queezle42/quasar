module Network.Rpc.Multiplexer (
  ChannelId,
  MessageId,
  MessageLength,
  Channel,
  MessageHeader(..),
  MessageHeaderResult(..),
  -- TODO rename (this class only exists for `reportProtocolError` and `reportLocalError`)
  reportProtocolError,
  reportLocalError,
  channelReportProtocolError,
  channelReportLocalError,
  channelSend,
  channelSend_,
  channelClose,
  channelSetHandler,
  ChannelMessageHandler,
  SimpleChannelMessageHandler,
  simpleMessageHandler,
  runMultiplexer,
  newMultiplexer,
) where

import Control.Concurrent.Async (async, link)
import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (Exception(..), MaskingState(Unmasked), catch, finally, interruptible, throwIO, getMaskingState, mask_)
import Control.Monad (when, unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (StateT, execStateT, runStateT)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode)
import qualified Data.Binary as Binary
import Data.Binary.Get (Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import Data.Tuple (swap)
import Data.Word
import Network.Rpc.Connection
import Prelude
import GHC.Generics
import System.IO (hPutStrLn, stderr)

type ChannelId = Word64
type MessageId = Word64
type MessageLength = Word64
-- | Low level network protocol type
data MultiplexerProtocolMessage
  = ChannelMessage [MultiplexerProtocolMessageHeader] MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | ProtocolError String
  | ChannelProtocolError ChannelId String
  deriving (Binary, Generic, Show)

-- | Low level network protocol message header type
data MultiplexerProtocolMessageHeader = CreateChannel
  deriving (Binary, Generic, Show)

newtype MessageHeader =
  -- | The callback is running in a masked state and is blocking all network traffic. The callback should only be used to register a callback on the channel and to store it; then it should return immediately.
  CreateChannelHeader (Channel -> IO ())
newtype MessageHeaderResult = CreateChannelHeaderResult Channel

data MultiplexerProtocolWorker = MultiplexerProtocolWorker {
  stateMVar :: MVar MultiplexerProtocolWorkerState,
  killReceiverMVar :: MVar (IO ())
}
data MultiplexerProtocolWorkerState = MultiplexerProtocolWorkerState {
  socketConnection :: Maybe Connection,
  channels :: HM.HashMap ChannelId Channel,
  sendChannel :: ChannelId,
  receiveChannel :: ChannelId,
  receiveNextChannelId :: ChannelId,
  sendNextChannelId :: ChannelId
}

data NotConnected = NotConnected
  deriving Show
instance Exception NotConnected


data Channel = Channel {
  channelId :: ChannelId,
  worker :: MultiplexerProtocolWorker,
  stateMVar :: MVar ChannelState,
  sendStateMVar :: MVar ChannelSendState,
  receiveStateMVar :: MVar ChannelReceiveState,
  handlerAtVar :: AtVar ChannelMessageHandler
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

type ChannelMessageHandler = MessageId -> [MessageHeaderResult] -> Decoder (IO ())
type SimpleChannelMessageHandler = MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()


-- | Starts a new multiplexer on an existing connection.
-- This starts a thread which runs until 'channelClose' is called on the resulting 'Channel' (use e.g. 'bracket' to ensure the channel is closed).
newMultiplexer :: forall a. (IsConnection a) => a -> IO Channel
newMultiplexer x = do
  channelMVar <- newEmptyMVar
  -- 'runMultiplexerProtcol' needs to be interruptible (so it can terminate when it is closed), so 'interruptible' is used to ensure that this function also works when used in 'bracket'
  mask_ $ link =<< async (interruptible (runMultiplexer (putMVar channelMVar) (toSocketConnection x)))
  takeMVar channelMVar

runMultiplexer :: (Channel -> IO ()) -> Connection -> IO ()
runMultiplexer channelSetupHook connection = do
  -- Running in masked state, this thread (running the receive-function) cannot be interrupted when closing the connection
  maskingState <- getMaskingState
  when (maskingState /= Unmasked) (fail "'runMultiplexerProtocol' cannot run in masked thread state.")

  threadId <- myThreadId
  killReceiverMVar <- newMVar $ throwTo threadId NotConnected
  let disarmKillReciver = modifyMVar_ killReceiverMVar $ \_ -> pure (pure ())

  stateMVar <- newMVar $ MultiplexerProtocolWorkerState {
    socketConnection = Just connection,
    channels = HM.empty,
    sendChannel = 0,
    receiveChannel = 0,
    receiveNextChannelId = undefined,
    sendNextChannelId = undefined
  }
  let worker = MultiplexerProtocolWorker {
    stateMVar,
    killReceiverMVar
  }
  (((channelSetupHook =<< newChannel worker 0 Connected) >> multiplexerProtocolReceive worker)
    `finally` (disarmKillReciver >> multiplexerConnectionClose worker))
      `catch` (\(_ex :: NotConnected) -> pure ())

multiplexerProtocolReceive :: MultiplexerProtocolWorker -> IO ()
multiplexerProtocolReceive worker = receiveThreadLoop multiplexerDecoder
  where
    multiplexerDecoder :: Decoder MultiplexerProtocolMessage
    multiplexerDecoder = runGetIncremental Binary.get
    receiveThreadLoop :: Decoder MultiplexerProtocolMessage -> IO a
    receiveThreadLoop (Fail _ _ errMsg) = reportProtocolError worker ("Failed to parse protocol message: " <> errMsg)
    receiveThreadLoop (Partial feedFn) = receiveThreadLoop . feedFn . Just =<< receiveThrowing
    receiveThreadLoop (Done leftovers _ msg) = do
      newLeftovers <- execStateT (handleMultiplexerMessage msg) leftovers
      receiveThreadLoop (pushChunk multiplexerDecoder newLeftovers)
    handleMultiplexerMessage :: MultiplexerProtocolMessage -> StateT BS.ByteString IO ()
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

    handleChannelMessage :: Channel -> [MultiplexerProtocolMessageHeader] -> MessageLength -> StateT BS.ByteString IO ()
    handleChannelMessage channel headers len = do
      decoder <- liftIO $ do
        -- Don't receive messages on closed channels
        channelState <- readMVar channel.stateMVar
        case channelState.connectionState of
          Connected -> do
            headerResults <- sequence (processHeader <$> headers)
            channelStartHandleMessage channel headerResults
          -- The channel is closed but the remote might not know that yet, so the message is silently ignored
          Closed -> closedChannelMessageHandler <$> sequence (processHeader <$> headers)
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
      liftIO $ withMVar worker.killReceiverMVar $ const channelCallback
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
        failedToParseMessage err = reportProtocolError worker ("Failed to parse message on channel " <> show channel.channelId <> ": " <> err)
        failedToConsumeAllInput :: MessageLength -> IO a
        failedToConsumeAllInput bytesRead = reportProtocolError worker ("Decoder for channel " <> show channel.channelId <> " failed to consume all input (" <> show (len - bytesRead) <> " bytes left)")
        failedToTerminate :: IO a
        failedToTerminate = reportLocalError worker ("Decoder on channel " <> show channel.channelId <> " failed to terminate after end-of-input")
        processHeader :: MultiplexerProtocolMessageHeader -> IO MessageHeaderResult
        processHeader CreateChannel = do
          channelId <- modifyMVar worker.stateMVar $ \workerState -> do
            let
              receiveNextChannelId = workerState.receiveNextChannelId
              newWorkerState = workerState{receiveNextChannelId = receiveNextChannelId + 2}
            pure (newWorkerState, receiveNextChannelId)
          modifyMVar channel.stateMVar $ \state -> do
            createdChannel <- newSubChannel channel.worker channelId channel
            let newState = state{
              children = createdChannel : state.children
            }
            pure (newState, CreateChannelHeaderResult createdChannel)
    receiveThrowing :: IO BS.ByteString
    receiveThrowing = do
      state <- readMVar worker.stateMVar
      maybe (throwIO NotConnected) (.receive) state.socketConnection


closedChannelMessageHandler :: [MessageHeaderResult] -> Decoder (IO ())
closedChannelMessageHandler headers = discardMessageDecoder $ mapM_ handleHeader headers
  where
    handleHeader :: MessageHeaderResult -> IO ()
    handleHeader (CreateChannelHeaderResult createdChannel) =
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

withMultiplexerState :: MultiplexerProtocolWorker -> StateT MultiplexerProtocolWorkerState IO a -> IO a
withMultiplexerState worker action = modifyMVar worker.stateMVar $ fmap swap . runStateT action

multiplexerSend :: MultiplexerProtocolWorker -> MultiplexerProtocolMessage -> IO ()
multiplexerSend worker msg = withMultiplexerState worker (multiplexerStateSend msg)

multiplexerStateSend :: MultiplexerProtocolMessage -> StateT MultiplexerProtocolWorkerState IO ()
multiplexerStateSend = multiplexerStateSendRaw . encode

multiplexerStateSendRaw :: BSL.ByteString -> StateT MultiplexerProtocolWorkerState IO ()
multiplexerStateSendRaw rawMsg = do
  state <- State.get
  case state.socketConnection of
    Nothing -> liftIO $ throwIO NotConnected
    Just connection -> liftIO $ connection.send rawMsg

multiplexerSendChannelMessage :: Channel -> BSL.ByteString -> [MessageHeader] -> IO ()
multiplexerSendChannelMessage channel msg headers = do
  -- Sending a channel message consists of multiple low-level send operations, so the MVar is held during the operation
  withMultiplexerState worker $ do
    multiplexerSwitchChannel channel.channelId

    headerMessages <- sequence (prepareHeader <$> headers)

    multiplexerStateSend (ChannelMessage headerMessages (fromIntegral (BSL.length msg)))
    multiplexerStateSendRaw msg
  where
    worker :: MultiplexerProtocolWorker
    worker = channel.worker
    prepareHeader :: MessageHeader -> StateT MultiplexerProtocolWorkerState IO MultiplexerProtocolMessageHeader
    prepareHeader (CreateChannelHeader newChannelCallback) = do
      nextChannelId <- State.state (\state -> (state.sendNextChannelId, state{sendNextChannelId = state.sendNextChannelId + 1}))
      createdChannel <- liftIO $ newSubChannel worker nextChannelId channel

      -- TODO we probably don't want to call the callback here, as the state is locked; we also don't want to call it later, because at that point messages could already arrive and the handler has to be set
      -- TODO: also we are currently holding the MultiplexerProtocolWorkerState which means sending messages from the callback will result in a deadlock - calling code must not do that. That's also an indication for a bad design
      -- TODO the current design requires the caller to use mvars/iorefs to get the created channel - also not optimal.
      liftIO $ newChannelCallback createdChannel
      pure CreateChannel

multiplexerSwitchChannel :: ChannelId -> StateT MultiplexerProtocolWorkerState IO ()
multiplexerSwitchChannel channelId = do
  -- Check if channel switch is required and update current channel
  shouldSwitchChannel <- State.state (\state -> (state.sendChannel /= channelId, state{sendChannel = channelId}))
  when shouldSwitchChannel $ multiplexerStateSend (SwitchChannel channelId)

-- | Closes a channel and all it's children: After the function completes, the channel callback will no longer be called on received messages and sending messages on the channel will fail.
-- Calling close on a closed channel is a noop.
channelClose :: Channel -> IO ()
channelClose channel = do
  -- Change channel state of all unclosed channels in the tree to closed
  channelWasClosed <- channelClose' channel

  when channelWasClosed $ do
    -- Send close message
    withMultiplexerState channel.worker $ do
      multiplexerSwitchChannel channel.channelId
      multiplexerStateSend CloseChannel

    -- Terminate the worker when the root channel is closed
    when (channel.channelId == 0) $ multiplexerClose channel.worker
  where
    channelClose' :: Channel -> IO Bool
    channelClose' chan = modifyMVar chan.stateMVar $ \state ->
      case state.connectionState of
        Connected -> do
          -- Close all children while blocking the state. This prevents children from receiving a messages after the parent channel has already rejected a message
          liftIO (mapM_ (void . channelClose') state.children)
          pure (state{connectionState = Closed}, True)
        -- Channel was already closed and can be ignored
        Closed -> pure (state, False)
        CloseConfirmed -> pure (state, False)

-- Called on a channel when a ChannelClose message is received
channelConfirmClose :: Channel -> IO ()
channelConfirmClose channel = do
  closeConfirmedIds <- channelClose' channel

  -- List can only be empty when the channel was already confirmed as closed
  unless (closeConfirmedIds == []) $ do
    -- Remote channels from worker
    withMultiplexerState channel.worker $ do
      State.modify $ \state -> state{channels = foldr HM.delete state.channels closeConfirmedIds}

    -- Terminate the worker when the root channel is closed
    when (channel.channelId == 0) $ multiplexerClose channel.worker
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

-- | Close a mulxiplexer worker by closing the connection it is based on and then stopping the worker thread.
multiplexerClose :: MultiplexerProtocolWorker -> IO ()
multiplexerClose worker = do
  multiplexerConnectionClose worker
  modifyMVar_ worker.killReceiverMVar $ \killReceiver -> do
    killReceiver
    -- Replace 'killReceiver'-action with a no-op to ensure it runs only once
    pure (pure ())

-- | Internal close operation: Closes the communication channel a multiplexer is operating on. The caller has the responsibility to ensure the receiver thread is closed.
multiplexerConnectionClose :: MultiplexerProtocolWorker -> IO ()
multiplexerConnectionClose worker = do
  modifyMVar_ worker.stateMVar $ \state -> do
    case state.socketConnection of
      Just connection -> connection.close
      Nothing -> pure ()
    pure state{socketConnection = Nothing}


reportProtocolError :: MultiplexerProtocolWorker -> String -> IO b
reportProtocolError worker message = do
  multiplexerSend worker $ ProtocolError message
  multiplexerConnectionClose worker
  -- TODO custom error type, close connection
  undefined

reportLocalError :: MultiplexerProtocolWorker -> String -> IO b
reportLocalError worker message = do
  hPutStrLn stderr message
  multiplexerSend worker $ ProtocolError "Internal server error"
  multiplexerConnectionClose worker
  -- TODO custom error type, close connection
  undefined

channelReportProtocolError :: Channel -> String -> IO b
channelReportProtocolError channel message = do
  -- TODO: send channelId as well
  multiplexerSend channel.worker $ ChannelProtocolError channel.channelId message
  multiplexerConnectionClose channel.worker
  -- TODO custom error type, close connection
  undefined

channelReportLocalError :: Channel -> String -> IO b
channelReportLocalError channel message = do
  hPutStrLn stderr $ "Local error on channel " <> show channel.channelId <> ": " <> message
  multiplexerSend channel.worker $ ProtocolError $ "Internal server error on channel " <> show channel.channelId
  multiplexerConnectionClose channel.worker
  -- TODO custom error type, close connection
  undefined

simpleMessageHandler :: SimpleChannelMessageHandler -> ChannelMessageHandler
simpleMessageHandler handler msgId headers = decoder ""
  where
    decoder :: BSL.ByteString -> Decoder (IO ())
    decoder acc = Partial (maybe done partial)
      where
        partial :: BS.ByteString -> Decoder (IO ())
        partial = decoder . (acc <>) . BSL.fromStrict
        done :: Decoder (IO ())
        done = Done "" (BSL.length acc) (handler msgId headers acc)

newSubChannel :: MultiplexerProtocolWorker -> ChannelId -> Channel -> IO Channel
newSubChannel worker channelId parent =
  modifyMVar parent.stateMVar $ \parentChannelState -> do
    -- Holding the parents channelState while initializing the channel will ensure the ChannelConnectivity is inherited atomically
    createdChannel <- newChannel worker channelId parentChannelState.connectionState

    let newParentState = parentChannelState{
      children = createdChannel : parentChannelState.children
    }
    pure (newParentState, createdChannel)

newChannel :: MultiplexerProtocolWorker -> ChannelId -> ChannelConnectivity -> IO Channel
newChannel worker channelId connectionState = do
  stateMVar <- newMVar ChannelState {
    connectionState,
    children = []
  }
  sendStateMVar <- newMVar ChannelSendState {
    nextMessageId = 0
  }
  receiveStateMVar <- newMVar ChannelReceiveState {
    nextMessageId = 0
  }
  handlerAtVar <- newEmptyAtVar
  let channel = Channel {
    worker,
    channelId,
    stateMVar,
    sendStateMVar,
    receiveStateMVar,
    handlerAtVar
  }
  modifyMVar_ worker.stateMVar $ \state -> pure state{channels = HM.insert channelId channel state.channels}
  pure channel

channelSend :: Channel -> [MessageHeader] -> BSL.ByteString -> (MessageId -> IO ()) -> IO ()
channelSend channel msg headers callback = do
  modifyMVar_ channel.sendStateMVar $ \state -> do
    -- Don't send on closed channels
    channelState <- readMVar channel.stateMVar
    unless (channelState.connectionState == Connected) $ throwIO ChannelNotConnected

    callback state.nextMessageId
    multiplexerSendChannelMessage channel headers msg
    pure state{nextMessageId = state.nextMessageId + 1}

channelSend_ :: Channel -> [MessageHeader] -> BSL.ByteString -> IO ()
channelSend_ channel headers msg = channelSend channel headers msg (const (pure ()))

channelStartHandleMessage :: Channel -> [MessageHeaderResult] -> IO (Decoder (IO ()))
channelStartHandleMessage channel headers = do
  msgId <- modifyMVar channel.receiveStateMVar $ \state ->
    pure (state{nextMessageId = state.nextMessageId + 1}, state.nextMessageId)
  handler <- readAtVar channel.handlerAtVar
  pure (handler msgId headers)

channelSetHandler :: Channel -> ChannelMessageHandler -> IO ()
channelSetHandler channel = writeAtVar channel.handlerAtVar

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
