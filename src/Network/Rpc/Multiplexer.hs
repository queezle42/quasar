module Network.Rpc.Multiplexer (
  SocketConnection(..),
  IsSocketConnection(..),
  ChannelId,
  MessageId,
  MessageLength,
  Channel,
  MessageHeader(..),
  MessageHeaderResult(..),
  -- TODO rename (this class only exists for unified error reporting and connection termination)
  HasMultiplexerProtocolWorker(..),
  reportProtocolError,
  reportLocalError,
  channelSend,
  channelSend_,
  channelClose,
  channelSetHandler,
  ChannelMessageHandler,
  SimpleChannelMessageHandler,
  simpleMessageHandler,
  runMultiplexerProtocol,
) where

import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (Exception(..), MaskingState(Unmasked), catch, finally, throwIO, getMaskingState)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (StateT, execStateT, get, put)
import Control.Concurrent.MVar
import Data.Binary (Binary, encode)
import qualified Data.Binary as Binary
import Data.Binary.Get (Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import Data.Word
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.Socket.ByteString.Lazy as SocketL
import Prelude
import GHC.Generics
import System.IO (hPutStrLn, stderr)

-- | Abstraction over a socket connection, to be able to switch to different communication channels (e.g. the dummy implementation for unit tests).
data SocketConnection = SocketConnection {
  send :: BSL.ByteString -> IO (),
  receive :: IO BS.ByteString,
  close :: IO ()
}
class IsSocketConnection a where
  toSocketConnection :: a -> SocketConnection
instance IsSocketConnection SocketConnection where
  toSocketConnection = id
instance IsSocketConnection Socket.Socket where
  toSocketConnection sock = SocketConnection {
    send=SocketL.sendAll sock,
    receive=Socket.recv sock 4096,
    close=Socket.gracefulClose sock 2000
  }

type ChannelId = Word64
type MessageId = Word64
type MessageLength = Word64
-- | Low level network protocol type
data MultiplexerProtocolMessage
  = ChannelMessage [MultiplexerProtocolMessageHeader] MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | ProtocolError String
  deriving (Binary, Generic, Show)

-- | Low level network protocol message header type
data MultiplexerProtocolMessageHeader = CreateChannel
  deriving (Binary, Generic, Show)

newtype MessageHeader = CreateChannelHeader (ChannelId -> IO ())
newtype MessageHeaderResult = CreateChannelHeaderResult Channel

data MultiplexerProtocolWorker = MultiplexerProtocolWorker {
  stateMVar :: MVar MultiplexerProtocolWorkerState,
  killReceiverMVar :: MVar (IO ())
}
data MultiplexerProtocolWorkerState = MultiplexerProtocolWorkerState {
  socketConnection :: Maybe SocketConnection,
  channels :: HM.HashMap ChannelId Channel,
  sendChannel :: ChannelId,
  receiveChannel :: ChannelId
}

class HasMultiplexerProtocolWorker a where
  getMultiplexerProtocolWorker :: a -> MultiplexerProtocolWorker
instance HasMultiplexerProtocolWorker MultiplexerProtocolWorker where
  getMultiplexerProtocolWorker = id

data NotConnected = NotConnected
  deriving Show
instance Exception NotConnected

runMultiplexerProtocol :: (Channel -> IO ()) -> SocketConnection -> IO ()
runMultiplexerProtocol channelSetupHook connection = do
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
    receiveChannel = 0
  }
  let worker = MultiplexerProtocolWorker {
    stateMVar,
    killReceiverMVar
  }
  (((channelSetupHook =<< newChannel worker 0) >> metaProtocolReceive worker)
    `finally` (disarmKillReciver >> metaConnectionClose worker))
      `catch` (\(_ex :: NotConnected) -> pure ())

metaProtocolReceive :: MultiplexerProtocolWorker -> IO ()
metaProtocolReceive worker = receiveThreadLoop metaDecoder
  where
    metaDecoder :: Decoder MultiplexerProtocolMessage
    metaDecoder = runGetIncremental Binary.get
    receiveThreadLoop :: Decoder MultiplexerProtocolMessage -> IO a
    receiveThreadLoop (Fail _ _ errMsg) = reportProtocolError worker ("Failed to parse protocol message: " <> errMsg)
    receiveThreadLoop (Partial feedFn) = receiveThreadLoop . feedFn . Just =<< receiveThrowing
    receiveThreadLoop (Done leftovers _ msg) = do
      newLeftovers <- execStateT (handleMultiplexerMessage msg) leftovers
      receiveThreadLoop (pushChunk metaDecoder newLeftovers)
    handleMultiplexerMessage :: MultiplexerProtocolMessage -> StateT BS.ByteString IO ()
    handleMultiplexerMessage (ChannelMessage headers len) = do
      workerState <- liftIO $ readMVar worker.stateMVar
      case HM.lookup workerState.receiveChannel workerState.channels of
        Just channel -> handleChannelMessage channel headers len
        Nothing -> liftIO $ reportProtocolError worker ("Received message on invalid channel: " <> show workerState.receiveChannel)
    handleMultiplexerMessage (SwitchChannel channelId) = liftIO $ modifyMVar_ worker.stateMVar $ \state -> pure state{receiveChannel=channelId}
    handleMultiplexerMessage x = liftIO $ print x >> undefined -- Unhandled meta message

    handleChannelMessage :: Channel -> [MultiplexerProtocolMessageHeader] -> MessageLength -> StateT BS.ByteString IO ()
    handleChannelMessage channel headers len = do
      headerResults <- liftIO $ sequence (processHeader <$> headers)
      decoder <- liftIO $ channelStartHandleMessage channel headerResults
      -- StateT currently contains leftovers
      initialLeftovers <- get
      let
        leftoversLength = fromIntegral $ BS.length initialLeftovers
        remaining = len - leftoversLength

      (channelCallback, leftovers) <- liftIO $ runDecoder remaining (pushChunk decoder initialLeftovers)

      -- Data is received in chunks but messages have a defined length, so leftovers are put back into StateT
      put leftovers
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
        processHeader CreateChannel = undefined
    receiveThrowing :: IO BS.ByteString
    receiveThrowing = do
      state <- readMVar worker.stateMVar
      maybe (throwIO NotConnected) (.receive) state.socketConnection


metaSend :: MultiplexerProtocolWorker -> MultiplexerProtocolMessage -> IO ()
metaSend worker msg = withMVar worker.stateMVar $ \state -> metaStateSend state msg

metaStateSend :: MultiplexerProtocolWorkerState -> MultiplexerProtocolMessage -> IO ()
metaStateSend state = metaStateSendRaw state . encode

metaStateSendRaw :: MultiplexerProtocolWorkerState -> BSL.ByteString -> IO ()
metaStateSendRaw MultiplexerProtocolWorkerState{socketConnection=Just connection} rawMsg = connection.send rawMsg
metaStateSendRaw MultiplexerProtocolWorkerState{socketConnection=Nothing} _ = throwIO NotConnected

metaSendChannelMessage :: MultiplexerProtocolWorker -> ChannelId -> BSL.ByteString -> [MessageHeader] -> IO ()
metaSendChannelMessage worker channelId msg headers = do
  -- Sending a channel message consists of multiple low-level send operations, so the MVar is held during the operation
  modifyMVar_ worker.stateMVar $ \state -> do
    -- Switch to the specified channel (if required)
    when (state.sendChannel /= channelId) $ metaSend worker (SwitchChannel channelId)

    headerMessages <- sequence (prepareHeader <$> headers)
    metaStateSend state (ChannelMessage headerMessages (fromIntegral (BSL.length msg)))
    metaStateSendRaw state msg
    pure state{sendChannel=channelId}
  where
    prepareHeader :: MessageHeader -> IO MultiplexerProtocolMessageHeader
    prepareHeader (CreateChannelHeader _newChannelCallback) = undefined


metaChannelClose :: MultiplexerProtocolWorker -> ChannelId -> IO ()
metaChannelClose worker channelId =
  if channelId == 0
    then metaClose worker
    else undefined

-- | Close a mulxiplexer worker by closing the connection it is based on and then stopping the worker thread.
metaClose :: MultiplexerProtocolWorker -> IO ()
metaClose worker = do
  metaConnectionClose worker
  modifyMVar_ worker.killReceiverMVar $ \killReceiver -> do
    killReceiver
    pure (pure ())

-- | Internal close operation: Closes the communication channel a multiplexer is operating on. The caller has the responsibility to ensure the receiver thread is closed.
metaConnectionClose :: MultiplexerProtocolWorker -> IO ()
metaConnectionClose worker = do
  modifyMVar_ worker.stateMVar $ \state -> do
    case state.socketConnection of
      Just connection -> connection.close
      Nothing -> pure ()
    pure state{socketConnection = Nothing}


reportProtocolError :: HasMultiplexerProtocolWorker a => a -> String -> IO b
reportProtocolError hasWorker message = do
  let worker = getMultiplexerProtocolWorker hasWorker
  modifyMVar_ worker.stateMVar $ \state -> do
    metaStateSend state $ ProtocolError message
    pure state
  -- TODO custom error type, close connection
  undefined

reportLocalError :: HasMultiplexerProtocolWorker a => a -> String -> IO b
reportLocalError hasWorker message = do
  hPutStrLn stderr message
  let worker = getMultiplexerProtocolWorker hasWorker
  modifyMVar_ worker.stateMVar $ \state -> do
    metaStateSend state $ ProtocolError "Internal server error"
    pure state
  -- TODO custom error type, close connection
  undefined

data Channel = Channel {
  channelId :: ChannelId,
  worker :: MultiplexerProtocolWorker,
  sendStateMVar :: MVar ChannelSendState,
  receiveStateMVar :: MVar ChannelReceiveState
}
instance HasMultiplexerProtocolWorker Channel where
  getMultiplexerProtocolWorker = (.worker)
newtype ChannelSendState = ChannelSendState {
  nextMessageId :: MessageId
}
data ChannelReceiveState = ChannelReceiveState {
  nextMessageId :: MessageId,
  handler :: ChannelMessageHandler
}

type ChannelMessageHandler = MessageId -> [MessageHeaderResult] -> Decoder (IO ())
type SimpleChannelMessageHandler = MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()

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


-- Should not be exported
newChannel :: MultiplexerProtocolWorker -> ChannelId -> IO Channel
newChannel worker channelId = do
  sendStateMVar <- newMVar ChannelSendState {
    nextMessageId = 0
  }
  let handler = simpleMessageHandler $ \_ _ _ -> reportLocalError worker ("Channel " <> show channelId <> ": Received message but no Handler is registered")
  receiveStateMVar <- newMVar ChannelReceiveState {
    nextMessageId = 0,
    handler
  }
  let channel = Channel {
    worker,
    channelId,
    sendStateMVar,
    receiveStateMVar
  }
  modifyMVar_ worker.stateMVar $ \state -> pure state{channels = HM.insert channelId channel state.channels}
  pure channel
channelSend :: Channel -> BSL.ByteString -> [MessageHeader] -> (MessageId -> IO ()) -> IO ()
channelSend channel msg headers callback = do
  modifyMVar_ channel.sendStateMVar $ \state -> do
    callback state.nextMessageId
    metaSendChannelMessage channel.worker channel.channelId msg headers
    pure state{nextMessageId = state.nextMessageId + 1}
channelSend_ :: Channel -> BSL.ByteString -> [MessageHeader] -> IO ()
channelSend_ channel msg headers = channelSend channel msg headers (const (pure ()))
channelClose :: Channel -> IO ()
channelClose channel = metaChannelClose channel.worker channel.channelId
channelStartHandleMessage :: Channel -> [MessageHeaderResult] -> IO (Decoder (IO ()))
channelStartHandleMessage channel headers = do
  (msgId, handler) <- modifyMVar channel.receiveStateMVar $ \state ->
    pure (state{nextMessageId = state.nextMessageId + 1}, (state.nextMessageId, state.handler))
  pure (handler msgId headers)
channelSetHandler :: Channel -> ChannelMessageHandler -> IO ()
channelSetHandler channel handler = modifyMVar_ channel.receiveStateMVar $ \state -> pure state{handler}
