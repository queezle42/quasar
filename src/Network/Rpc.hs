module Network.Rpc where

import Control.Concurrent (threadDelay, forkFinally, myThreadId, throwTo)
import Control.Concurrent.Async (Async, async, cancel, link, waitCatch, withAsync)
import Control.Exception (Exception(..), SomeException, MaskingState(Unmasked), bracket, bracketOnError, catch, finally, throwIO, bracketOnError, onException, getMaskingState)
import Control.Monad ((>=>), when, unless, forever, forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (State, StateT, execState, execStateT, get, put)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode, decodeOrFail)
import qualified Data.Binary as Binary
import Data.Binary.Get (Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.List (intercalate)
import Data.Maybe (isNothing)
import Data.Word
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.Socket.ByteString.Lazy as SocketL
import Prelude
import GHC.IO (unsafeUnmask)
import GHC.Generics
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (getFileStatus, isSocket)

-- * Rpc api definition

data RpcApi = RpcApi {
  name :: String,
  functions :: [ RpcFunction ]
}

data RpcFunction = RpcFunction {
  name :: String,
  arguments :: [RpcArgument],
  results :: [RpcResult],
  fixedHandler :: Maybe (Q Exp)
}

data RpcArgument = RpcArgument {
  name :: String,
  ty :: Q Type
}

data RpcResult = RpcResult {
  name :: String,
  ty :: Q Type
}

rpcApi :: String -> [RpcFunction] -> RpcApi
rpcApi apiName functions = RpcApi {
  name = apiName,
  functions = functions
}

rpcFunction :: String -> State RpcFunction () -> RpcFunction
rpcFunction methodName setup = execState setup RpcFunction {
    name = methodName,
    arguments = [],
    results = [],
    fixedHandler = Nothing
  }

addArgument :: String -> Q Type -> State RpcFunction ()
addArgument name t = State.modify (\fun -> fun{arguments = fun.arguments <> [RpcArgument name t]})

addResult :: String -> Q Type -> State RpcFunction ()
addResult name t = State.modify (\fun -> fun{results = fun.results <> [RpcResult name t]})

setFixedHandler :: Q Exp -> State RpcFunction ()
setFixedHandler handler = State.modify (\fun -> fun{fixedHandler = Just handler})

-- * Template Haskell rpc protocol generator


-- | Generates rpc protocol types, rpc client and rpc server
makeRpc :: RpcApi -> Q [Dec]
makeRpc api = mconcat <$> sequence [makeProtocol api, makeClient api, makeServer api]

makeProtocol :: RpcApi -> Q [Dec]
makeProtocol api@RpcApi{functions} = sequence [protocolDec, protocolInstanceDec, messageDec, responseDec]
  where
    protocolDec :: Q Dec
    protocolDec = dataD (pure []) (protocolTypeName api) [] Nothing [] []

    protocolInstanceDec :: Q Dec
    protocolInstanceDec = instanceD (cxt []) (appT (conT ''RpcProtocol) (protocolType api)) [
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolRequest) (protocolType api)) (conT (requestTypeName api))),
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolResponse) (protocolType api)) (conT (responseTypeName api)))
      ]

    messageDec :: Q Dec
    messageDec = dataD (pure []) (requestTypeName api) [] Nothing (messageCon <$> functions) serializableTypeDerivClauses
      where
        messageCon :: RpcFunction -> Q Con
        messageCon fun = normalC (requestFunctionCtorName api fun) (messageConVar <$> fun.arguments)
          where
            messageConVar :: RpcArgument -> Q BangType
            messageConVar (RpcArgument _name ty) = defaultBangType ty

    responseDec :: Q Dec
    responseDec = dataD (pure []) (responseTypeName api) [] Nothing (responseCon <$> filter hasResult functions) serializableTypeDerivClauses
      where
        responseCon :: RpcFunction -> Q Con
        responseCon fun = normalC (responseFunctionCtorName api fun) [defaultBangType (resultTupleType fun)]
        resultTupleType :: RpcFunction -> Q Type
        resultTupleType fun = buildTupleType (sequence ((.ty) <$> fun.results))

    serializableTypeDerivClauses :: [Q DerivClause]
    serializableTypeDerivClauses = [
      derivClause Nothing [[t|Eq|], [t|Show|], [t|Generic|], [t|Binary|]]
      ]

makeClient :: RpcApi -> Q [Dec]
makeClient api@RpcApi{functions} = do
  mconcat <$> mapM makeClientFunction functions
  where
    makeClientFunction :: RpcFunction -> Q [Dec]
    makeClientFunction fun = do
      clientVarName <- newName "client"
      varNames <- sequence (newName . (.name) <$> fun.arguments)
      makeClientFunction' clientVarName varNames
      where
        funName :: Name
        funName = mkName fun.name
        makeClientFunction' :: Name -> [Name] -> Q [Dec]
        makeClientFunction' clientVarName varNames = do
          funArgTypes <- functionArgumentTypes fun
          clientType <- [t|Client $(protocolType api)|]
          sequence [
            sigD funName (buildFunctionType (pure ([clientType] <> funArgTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]),
            funD funName [clause ([varP clientVarName] <> varPats) body []]
            ]
          where
            clientE :: Q Exp
            clientE = varE clientVarName
            varPats :: [Q Pat]
            varPats = varP <$> varNames
            body :: Q Body
            body
              | hasResult fun = normalB $ checkResult (requestE requestDataE)
              | otherwise = normalB $ sendE requestDataE
            requestDataE :: Q Exp
            requestDataE = applyVars (conE (requestFunctionCtorName api fun))
            sendE :: Q Exp -> Q Exp
            sendE msgExp = [|$typedSend $(clientE) $(msgExp)|]
            requestE :: Q Exp -> Q Exp
            requestE msgExp = [|$typedRequest $(clientE) $(msgExp)|]
            applyVars :: Q Exp -> Q Exp
            applyVars = go varNames
              where
                go :: [Name] -> Q Exp -> Q Exp
                go [] ex = ex
                go (n:ns) ex = go ns (appE ex (varE n))
            -- check and unbox the response of a request to the result type
            checkResult :: Q Exp -> Q Exp
            checkResult x = [|$x >>= $(lamCaseE [valid, invalid])|]
              where
                valid :: Q Match
                valid = do
                  result <- newName "result"
                  match (conP (responseFunctionCtorName api fun) [varP result]) (normalB [|pure $(varE result)|]) []
                invalid :: Q Match
                invalid = match wildP (normalB [|reportProtocolError $clientE "TODO"|]) []

            typedSend :: Q Exp
            typedSend = appTypeE [|clientSend|] (protocolType api)
            typedRequest :: Q Exp
            typedRequest = appTypeE [|clientRequestBlocking|] (protocolType api)


makeServer :: RpcApi -> Q [Dec]
makeServer api@RpcApi{functions} = sequence [handlerRecordDec, logicInstanceDec]
  where
    handlerRecordDec :: Q Dec
    handlerRecordDec = dataD (pure []) (implTypeName api) [] Nothing [recC (implTypeName api) (handlerRecordField <$> functionsWithoutBuiltinHandler)] []
    functionsWithoutBuiltinHandler :: [RpcFunction]
    functionsWithoutBuiltinHandler = filter (isNothing . fixedHandler) functions
    handlerRecordField :: RpcFunction -> Q VarBangType
    handlerRecordField fun = varDefaultBangType (implFieldName api fun) (handlerFunctionType fun)
    handlerFunctionType :: RpcFunction -> Q Type
    handlerFunctionType fun = buildFunctionType (functionArgumentTypes fun) [t|IO $(buildTupleType (functionResultTypes fun))|]

    logicInstanceDec :: Q Dec
    logicInstanceDec = instanceD (cxt []) [t|HasProtocolImpl $(protocolType api)|] [
      tySynInstD (tySynEqn Nothing [t|ProtocolImpl $(protocolType api)|] (implType api)),
      messageHandler
      ]
    messageHandler :: Q Dec
    messageHandler = do
      handleMessagePrimeName <- newName "handleMessage"
      implName <- newName "impl"
      funD 'handleMessage [clause [varP implName] (normalB (varE handleMessagePrimeName)) [handleMessagePrimeDec handleMessagePrimeName implName]]
      where
        handleMessagePrimeDec :: Name -> Name -> Q Dec
        handleMessagePrimeDec handleMessagePrimeName implName = funD handleMessagePrimeName (handlerFunctionClause <$> functions)
          where
            handlerFunctionClause :: RpcFunction -> Q Clause
            handlerFunctionClause fun = do
              varNames <- sequence (newName . (.name) <$> fun.arguments)
              serverLogicHandlerFunctionClause' varNames
              where
                serverLogicHandlerFunctionClause' :: [Name] -> Q Clause
                serverLogicHandlerFunctionClause' varNames = clause [conP (requestFunctionCtorName api fun) varPats] body []
                  where
                    varPats :: [Q Pat]
                    varPats = varP <$> varNames
                    body :: Q Body
                    body
                      | hasResult fun = normalB [|fmap Just $(packResponse (applyVars implExp))|]
                      | otherwise = normalB [|Nothing <$ $(applyVars implExp)|]
                    packResponse :: Q Exp -> Q Exp
                    packResponse = fmapE (conE (responseFunctionCtorName api fun))
                    applyVars :: Q Exp -> Q Exp
                    applyVars = go varNames
                      where
                        go :: [Name] -> Q Exp -> Q Exp
                        go [] ex = ex
                        go (n:ns) ex = go ns (appE ex (varE n))
                    implExp :: Q Exp
                    implExp = implExp' fun.fixedHandler
                      where
                        implExp' :: Maybe (Q Exp) -> Q Exp
                        implExp' Nothing = varE (implFieldName api fun) `appE` varE implName
                        implExp' (Just handler) = [|
                          let
                            impl :: $(implSig)
                            impl = $(handler)
                          in impl
                          |]
                    implSig :: Q Type
                    implSig = handlerFunctionType fun

-- * Runtime

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

class (Binary (ProtocolRequest p), Binary (ProtocolResponse p)) => RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p

type ProtocolResponseWrapper p = (MessageId, ProtocolResponse p)

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

data ConnectionIsClosed = ConnectionIsClosed
  deriving Show
instance Exception ConnectionIsClosed

runMultiplexerProtocol :: (Channel -> IO ()) -> SocketConnection -> IO ()
runMultiplexerProtocol channelSetupHook connection = do
  -- Running in masked state, this thread (running the receive-function) cannot be interrupted when closing the connection
  maskingState <- getMaskingState
  when (maskingState /= Unmasked) (fail "'runMultiplexerProtocol' cannot run in masked thread state.")

  threadId <- myThreadId
  killReceiverMVar <- newMVar $ throwTo threadId ConnectionIsClosed
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
      `catch` (\(_ex :: ConnectionIsClosed) -> pure ())

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
      maybe (throwIO ConnectionIsClosed) (.receive) state.socketConnection


metaSend :: MultiplexerProtocolWorker -> MultiplexerProtocolMessage -> IO ()
metaSend worker msg = withMVar worker.stateMVar $ \state -> metaStateSend state msg

metaStateSend :: MultiplexerProtocolWorkerState -> MultiplexerProtocolMessage -> IO ()
metaStateSend state = metaStateSendRaw state . encode

metaStateSendRaw :: MultiplexerProtocolWorkerState -> BSL.ByteString -> IO ()
metaStateSendRaw MultiplexerProtocolWorkerState{socketConnection=Just connection} rawMsg = connection.send rawMsg
metaStateSendRaw MultiplexerProtocolWorkerState{socketConnection=Nothing} _ = undefined

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

metaClose :: MultiplexerProtocolWorker -> IO ()
metaClose worker = do
  metaConnectionClose worker
  modifyMVar_ worker.killReceiverMVar $ \killReceiver -> do
    killReceiver
    pure (pure ())

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
type SimpleChannelMessageHandler = MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
type ChannelMessageHandler = MessageId -> [MessageHeaderResult] -> Decoder (IO ())

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
  let handler = (simpleMessageHandler $ \_ _ _ -> reportLocalError worker ("Channel " <> show channelId <> ": Received message but no Handler is registered"))
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


class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleMessage :: ProtocolImpl p -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))


data Client p = Client {
  channel :: Channel,
  stateMVar :: MVar (ClientState p)
}
instance HasMultiplexerProtocolWorker (Client p) where
  getMultiplexerProtocolWorker = (.channel.worker)
newtype ClientState p = ClientState {
  callbacks :: HM.HashMap MessageId (ProtocolResponse p -> IO ())
}
emptyClientState :: ClientState p
emptyClientState = ClientState {
  callbacks = HM.empty
}

clientSend :: RpcProtocol p => Client p -> ProtocolRequest p -> IO ()
clientSend client req = channelSend_ client.channel (encode req) []
clientRequestBlocking :: forall p. RpcProtocol p => Client p -> ProtocolRequest p -> IO (ProtocolResponse p)
clientRequestBlocking client req = do
  resultMVar <- newEmptyMVar
  channelSend client.channel (encode req) [] $ \msgId ->
    modifyMVar_ client.stateMVar $
      \state -> pure state{callbacks = HM.insert msgId (requestCompletedCallback resultMVar msgId) state.callbacks}
  -- Block on resultMVar until the request completes
  -- TODO: Future-based variant
  takeMVar resultMVar
  where
    requestCompletedCallback :: MVar (ProtocolResponse p) -> MessageId -> ProtocolResponse p -> IO ()
    requestCompletedCallback resultMVar msgId response = do
      -- Remove callback
      modifyMVar_ client.stateMVar $ \state -> pure state{callbacks = HM.delete msgId state.callbacks}
      putMVar resultMVar response
clientHandleChannelMessage :: forall p. (RpcProtocol p) => Client p -> MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
clientHandleChannelMessage client _msgId headers msg = case decodeOrFail msg of
  Left (_, _, errMsg) -> reportProtocolError client errMsg
  Right ("", _, resp) -> clientHandleResponse resp
  Right (leftovers, _, _) -> reportProtocolError client ("Response parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    clientHandleResponse :: ProtocolResponseWrapper p -> IO ()
    clientHandleResponse (requestId, resp) = do
      callback <- modifyMVar client.stateMVar $ \state -> do
        let (callbacks, mCallback) = lookupDelete requestId state.callbacks
        case mCallback of
          Just callback -> pure (state{callbacks}, callback)
          Nothing -> reportProtocolError client ("Received response with invalid request id " <> show requestId)
      callback resp

clientClose :: Client p -> IO ()
clientClose client = channelClose client.channel


serverHandleChannelMessage :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
serverHandleChannelMessage protocolImpl channel msgId headers msg = case decodeOrFail msg of
    Left (_, _, errMsg) -> reportProtocolError channel errMsg
    Right ("", _, req) -> serverHandleChannelRequest req
    Right (leftovers, _, _) -> reportProtocolError channel ("Request parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    serverHandleChannelRequest :: ProtocolRequest p -> IO ()
    serverHandleChannelRequest req = handleMessage @p protocolImpl req >>= maybe (pure ()) serverSendResponse
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSend_ channel (encode wrappedResponse) []
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (msgId, response)

registerChannelServerHandler :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> IO ()
registerChannelServerHandler protocolImpl channel = channelSetHandler channel (simpleMessageHandler (serverHandleChannelMessage @p protocolImpl channel))


-- ** Running client and server

newtype ConnectionFailed = ConnectionFailed [(Socket.AddrInfo, SomeException)]
  deriving (Show)
instance Exception ConnectionFailed where
  displayException (ConnectionFailed attemts) = "Connection attempts failed:\n" <> intercalate "\n" (map (\(addr, err) -> show (Socket.addrAddress addr) <> ": " <> displayException err) attemts)

withClientTCP :: RpcProtocol p => Socket.HostName -> Socket.ServiceName -> (Client p -> IO a) -> IO a
withClientTCP host port = bracket (newClientTCP host port) clientClose

newClientTCP :: forall p. RpcProtocol p => Socket.HostName -> Socket.ServiceName -> IO (Client p)
newClientTCP host port = do
  -- 'getAddrInfo' either pures a non-empty list or throws an exception
  (best:others) <- Socket.getAddrInfo (Just hints) (Just host) (Just port)

  connectTasksMVar <- newMVar []
  sockMVar <- newEmptyMVar
  let
    spawnConnectTask :: Socket.AddrInfo -> IO ()
    spawnConnectTask = \addr -> modifyMVar_ connectTasksMVar $ \old -> (:old) . (addr,) <$> connectTask addr
    -- Race more connections (a missed TCP SYN will result in 3s wait before a retransmission; IPv6 might be broken)
    -- Inspired by a similar implementation in browsers
    raceConnections :: IO ()
    raceConnections = do
      spawnConnectTask best
      threadDelay 200000
      -- Give the "best" address another try, in case the TCP SYN gets dropped
      spawnConnectTask best
      threadDelay 100000
      -- Try to connect to all other resolved addresses to prevent waiting for e.g. a long IPv6 connection timeout
      forM_ others spawnConnectTask
      -- Wait for all tasks to complete, throw an exception if all connections failed
      connectTasks <- readMVar connectTasksMVar
      results <- mapM (\(addr, task) -> (addr,) <$> waitCatch task) connectTasks
      forM_ (collect results) (throwIO . ConnectionFailed . reverse)
    collect :: [(Socket.AddrInfo, Either SomeException ())] -> Maybe [(Socket.AddrInfo, SomeException)]
    collect ((_, Right ()):_) = Nothing
    collect ((addr, Left ex):xs) = ((addr, ex):) <$> collect xs
    collect [] = Just []
    connectTask :: Socket.AddrInfo -> IO (Async ())
    connectTask addr = async $ do
      sock <- connect addr
      isFirst <- tryPutMVar sockMVar sock
      unless isFirst $ Socket.close sock

  -- The 'raceConnections'-async is 'link'ed to this thread, so 'readMVar' is interrupted when all connection attempts fail
  sock <-
    (withAsync (unsafeUnmask raceConnections) (link >=> const (readMVar sockMVar))
      `finally` (mapM_ (cancel . snd) =<< readMVar connectTasksMVar))
        `onException` (mapM_ Socket.close =<< tryTakeMVar sockMVar)
    -- As soon as we have an open connection, stop spawning more connections
  newClient sock
  where
    hints :: Socket.AddrInfo
    hints = Socket.defaultHints { Socket.addrFlags = [Socket.AI_ADDRCONFIG], Socket.addrSocketType = Socket.Stream }
    connect :: Socket.AddrInfo -> IO Socket.Socket
    connect addr = bracketOnError (openSocket addr) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.connect sock $ Socket.addrAddress addr
      pure sock

withClientUnix :: RpcProtocol p => FilePath -> (Client p -> IO a) -> IO a
withClientUnix socketPath = bracket (newClientUnix socketPath) clientClose

newClientUnix :: RpcProtocol p => FilePath -> IO (Client p)
newClientUnix socketPath = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
  Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
  Socket.connect sock $ Socket.SockAddrUnix socketPath
  newClient sock


withClient :: forall p a b. (IsSocketConnection a, RpcProtocol p) => a -> (Client p -> IO b) -> IO b
withClient x = bracket (newClient x) clientClose

newClient :: forall p a. (IsSocketConnection a, RpcProtocol p) => a -> IO (Client p)
newClient x = do
  clientMVar <- newEmptyMVar
  -- 'runMultiplexerProtcol' needs to be interruptible (so it can terminate when it is closed), so 'unsafeUnmask' is used to ensure that this function also works when used in 'bracket'
  link =<< async (unsafeUnmask (runMultiplexerProtocol (newChannelClient >=> putMVar clientMVar) (toSocketConnection x)))
  takeMVar clientMVar


newChannelClient :: RpcProtocol p => Channel -> IO (Client p)
newChannelClient channel = do
  stateMVar <- newMVar emptyClientState
  let client = Client {
    channel,
    stateMVar
  }
  channelSetHandler channel (simpleMessageHandler (clientHandleChannelMessage client))
  pure client

listenTCP :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> IO ()
listenTCP protocolImpl mhost port = do
  addr <- resolve
  bracket (open addr) Socket.close (listenOnBoundSocket @p protocolImpl)
  where
    resolve :: IO Socket.AddrInfo
    resolve = do
      let hints = Socket.defaultHints {Socket.addrFlags=[Socket.AI_PASSIVE], Socket.addrSocketType=Socket.Stream}
      (addr:_) <- Socket.getAddrInfo (Just hints) mhost (Just port)
      pure addr
    open :: Socket.AddrInfo -> IO Socket.Socket
    open addr = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.bind sock (Socket.addrAddress addr)
      pure sock

listenUnix :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> FilePath -> IO ()
listenUnix protocolImpl socketPath = bracket create Socket.close (listenOnBoundSocket @p protocolImpl)
  where
    create :: IO Socket.Socket
    create = do
      fileStatus <- getFileStatus socketPath
      let socketExists = isSocket fileStatus
      when socketExists (fail "Socket already exists")
      bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.bind sock (Socket.SockAddrUnix socketPath)
        pure sock

-- | Listen and accept connections on an already bound socket.
listenOnBoundSocket :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Socket.Socket -> IO ()
listenOnBoundSocket protocolImpl sock = do
  Socket.listen sock 1024
  forever $ do
    (conn, _sockAddr) <- Socket.accept sock
    forkFinally (runServerHandler @p protocolImpl conn) (socketFinalization conn)
  where
    socketFinalization :: Socket.Socket -> Either SomeException () -> IO ()
    socketFinalization conn (Left _err) = do
      -- TODO: log error
      --logStderr $ "Client connection closed with error " <> show err
      Socket.gracefulClose conn 2000
    socketFinalization conn (Right ()) = do
      Socket.gracefulClose conn 2000

runServerHandler :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsSocketConnection a) => ProtocolImpl p -> a -> IO ()
runServerHandler protocolImpl = runMultiplexerProtocol (registerChannelServerHandler @p protocolImpl) . toSocketConnection

-- ** Test implementation

withDummyClientServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> (Client p -> IO a) -> IO a
withDummyClientServer impl runClientHook = do
  (clientSocket, serverSocket) <- newDummySocketPair
  withAsync (runServerHandler @p impl serverSocket) $ \serverTask -> do
    link serverTask
    withClient clientSocket runClientHook

newDummySocketPair :: IO (SocketConnection, SocketConnection)
newDummySocketPair = do
  upstream <- newEmptyMVar
  downstream <- newEmptyMVar
  let x = SocketConnection {
    send=putMVar upstream . BSL.toStrict,
    receive=takeMVar downstream,
    close=pure ()
  }
  let y = SocketConnection {
    send=putMVar downstream . BSL.toStrict,
    receive=takeMVar upstream,
    close=pure ()
  }
  pure (x, y)


-- * Internal
--
-- ** Protocol generator helpers

functionArgumentTypes :: RpcFunction -> Q [Type]
functionArgumentTypes fun = sequence $ (.ty) <$> fun.arguments
functionResultTypes :: RpcFunction -> Q [Type]
functionResultTypes fun = sequence $ (.ty) <$> fun.results

hasFixedHandler :: RpcFunction -> Bool
hasFixedHandler RpcFunction{fixedHandler = Nothing} = False
hasFixedHandler _ = True

hasResult :: RpcFunction -> Bool
hasResult fun = not (null fun.results)


-- *** Name helper functions

protocolTypeName :: RpcApi -> Name
protocolTypeName RpcApi{name} = mkName (name <> "Protocol")

protocolType :: RpcApi -> Q Type
protocolType = conT . protocolTypeName

requestTypeIdentifier :: RpcApi -> String
requestTypeIdentifier RpcApi{name} = name <> "ProtocolRequest"

requestTypeName :: RpcApi -> Name
requestTypeName = mkName . requestTypeIdentifier

requestFunctionCtorName :: RpcApi -> RpcFunction -> Name
requestFunctionCtorName api fun = mkName (requestTypeIdentifier api <> "_" <> fun.name)

responseTypeIdentifier :: RpcApi -> String
responseTypeIdentifier RpcApi{name} = name <> "ProtocolResponse"

responseTypeName :: RpcApi -> Name
responseTypeName = mkName . responseTypeIdentifier

responseFunctionCtorName :: RpcApi -> RpcFunction -> Name
responseFunctionCtorName api fun = mkName (responseTypeIdentifier api <> "_" <> fun.name)

implTypeName :: RpcApi -> Name
implTypeName RpcApi{name} = mkName $ name <> "ProtocolImpl"

implType :: RpcApi -> Q Type
implType = conT . implTypeName

implFieldName :: RpcApi -> RpcFunction -> Name
implFieldName _api fun = mkName (fun.name <> "Impl")

-- ** Template Haskell helper functions

funT :: Q Type -> Q Type -> Q Type
funT x = appT (appT arrowT x)
infixr 0 `funT`

buildTupleType :: Q [Type] -> Q Type
buildTupleType fields = buildTupleType' =<< fields
  where
    buildTupleType' :: [Type] -> Q Type
    buildTupleType' [] = tupleT 0
    buildTupleType' [single] = pure single
    buildTupleType' fs = pure $ go (TupleT (length fs)) fs
    go :: Type -> [Type] -> Type
    go t [] = t
    go t (f:fs) = go (AppT t f) fs

buildFunctionType :: Q [Type] -> Q Type -> Q Type
buildFunctionType argTypes pureType = go =<< argTypes
  where
    go :: [Type] -> Q Type
    go [] = pureType
    go (t:ts) = pure t `funT` go ts

defaultBangType  :: Q Type -> Q BangType
defaultBangType = bangType (bang noSourceUnpackedness noSourceStrictness)

varDefaultBangType  :: Name -> Q Type -> Q VarBangType
varDefaultBangType name qType = varBangType name $ bangType (bang noSourceUnpackedness noSourceStrictness) qType

fmapE :: Q Exp -> Q Exp -> Q Exp
fmapE f = appE (appE (varE 'fmap) f)

-- ** General helper functions

-- | Lookup and delete a value from a HashMap in one operation
lookupDelete :: forall k v. (Eq k, Hashable k) => k -> HM.HashMap k v -> (HM.HashMap k v, Maybe v)
lookupDelete key m = State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (HM.HashMap k v)
    fn = HM.alterF (\c -> State.put c >> pure Nothing) key m

withAsyncLinked :: IO a -> (Async a -> IO b) -> IO b
withAsyncLinked inner outer = withAsync inner $ \task -> link task >> outer task

withAsyncLinked_ :: IO a -> IO b -> IO b
withAsyncLinked_ x = withAsyncLinked x . const


-- | Reimplementation of 'openSocket' from the 'network'-package, which got introduced in version 3.1.2.0. Should be removed later.
openSocket :: Socket.AddrInfo -> IO Socket.Socket
openSocket addr = Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)
