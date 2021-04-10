module Network.Rpc where

import Control.Concurrent.Async (Async, AsyncCancelled, async, cancel)
import Control.Exception (Exception(..), SomeException, Handler(..), catches, throwIO)
import Control.Monad ((<=<), when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (State, StateT, execState, execStateT, get, put)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode, decodeOrFail)
import qualified Data.Binary as Binary
import Data.Binary.Get (Decoder(..), runGetIncremental, pushChunk)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Functor ((<&>))
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.Maybe (isNothing)
import Data.Word
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.Socket.ByteString.Lazy as SocketL
import Prelude
import GHC.Generics
import System.IO (hPutStrLn, stderr)

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

makeProtocol :: RpcApi -> Q [Dec]
makeProtocol api@RpcApi{functions} = sequence [protocolDec, protocolInstanceDec, messageDec, responseDec]
  where
    protocolDec :: Q Dec
    protocolDec = dataD (return []) (protocolTypeName api) [] Nothing [] []

    protocolInstanceDec :: Q Dec
    protocolInstanceDec = instanceD (cxt []) (appT (conT ''RpcProtocol) (protocolType api)) [
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolRequest) (protocolType api)) (conT (requestTypeName api))),
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolResponse) (protocolType api)) (conT (responseTypeName api)))
      ]

    messageDec :: Q Dec
    messageDec = dataD (return []) (requestTypeName api) [] Nothing (messageCon <$> functions) serializableTypeDerivClauses
      where
        messageCon :: RpcFunction -> Q Con
        messageCon fun = normalC (requestFunctionCtorName api fun) (messageConVar <$> fun.arguments)
          where
            messageConVar :: RpcArgument -> Q BangType
            messageConVar (RpcArgument _name ty) = defaultBangType ty

    responseDec :: Q Dec
    responseDec = dataD (return []) (responseTypeName api) [] Nothing (responseCon <$> filter hasResult functions) serializableTypeDerivClauses
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
            sigD funName (buildFunctionType (return ([clientType] <> funArgTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]),
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
                  match (conP (responseFunctionCtorName api fun) [varP result]) (normalB [|return $(varE result)|]) []
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
    handlerRecordDec = dataD (return []) (implTypeName api) [] Nothing [recC (implTypeName api) (handlerRecordField <$> functionsWithoutBuiltinHandler)] []
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
    close=Socket.close sock
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
data MetaProtocolMessage
  = ChannelMessage [MetaProtocolMessageHeader] MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | ProtocolError String
  deriving (Binary, Generic, Show)

-- | Low level network protocol message header type
data MetaProtocolMessageHeader = CreateChannel
  deriving (Binary, Generic, Show)

newtype MessageHeader = CreateChannelHeader (ChannelId -> IO ())
newtype MessageHeaderResult = CreateChannelHeaderResult Channel

data MetaProtocolWorker = MetaProtocolWorker {
  stateMVar :: MVar MetaProtocolWorkerState,
  receiveTask :: Async ()
}
data MetaProtocolWorkerState = MetaProtocolWorkerState {
  socketConnection :: Maybe SocketConnection,
  channels :: HM.HashMap ChannelId Channel,
  sendChannel :: ChannelId,
  receiveChannel :: ChannelId
}

class HasMetaProtocolWorker a where
  getMetaProtocolWorker :: a -> MetaProtocolWorker
instance HasMetaProtocolWorker MetaProtocolWorker where
  getMetaProtocolWorker = id

data ConnectionIsClosed = ConnectionIsClosed
  deriving Show
instance Exception ConnectionIsClosed

newMetaProtocolWorker :: SocketConnection -> IO Channel
newMetaProtocolWorker connection = do
  stateMVar <- newMVar $ MetaProtocolWorkerState {
    socketConnection = Just connection,
    channels = HM.empty,
    sendChannel = 0,
    receiveChannel = 0
  }
  -- The worker needs to contain the task, but the task needs the worker, so it's passed via MVar
  workerMVar <- newEmptyMVar
  receiveTask <- async (receiveThread =<< readMVar workerMVar)
  let worker = MetaProtocolWorker {
    receiveTask,
    stateMVar
  }
  putMVar workerMVar worker
  newChannel worker 0
  where
    receiveThread :: MetaProtocolWorker -> IO ()
    receiveThread worker = catches (receiveThreadLoop metaDecoder) [
      Handler (\(_ex :: ConnectionIsClosed) -> return ()),
      Handler (\(_ex :: AsyncCancelled) -> return ()),
      Handler (\(_ex :: SomeException) -> undefined)
      ]
      where
        metaDecoder :: Decoder MetaProtocolMessage
        metaDecoder = runGetIncremental Binary.get
        receiveThreadLoop :: Decoder MetaProtocolMessage -> IO a
        receiveThreadLoop (Fail _ _ errMsg) = reportProtocolError worker ("Failed to parse protocol message: " <> errMsg)
        receiveThreadLoop (Partial feedFn) = receiveThreadLoop . feedFn . Just =<< receiveThrowing
        receiveThreadLoop (Done leftovers _ msg) = do
          newLeftovers <- execStateT (handleMetaMessage msg) leftovers
          receiveThreadLoop (pushChunk metaDecoder newLeftovers)
        handleMetaMessage :: MetaProtocolMessage -> StateT BS.ByteString IO ()
        handleMetaMessage (ChannelMessage headers len) = do
          workerState <- liftIO $ readMVar worker.stateMVar
          case HM.lookup workerState.receiveChannel workerState.channels of
            Just channel -> do
              -- StateT currently contains leftovers
              (rawMsg, leftovers) <- liftIO . readRawMessage . BSL.fromStrict =<< get
              -- Data is received in chunks but messages have a defined length, so leftovers are put back into StateT
              put $ BSL.toStrict leftovers
              headerResults <- liftIO $ sequence (processHeader <$> headers)
              liftIO $ channelHandleMessage channel headerResults rawMsg
            Nothing -> liftIO $ reportProtocolError worker ("Received message on invalid channel: " <> show workerState.receiveChannel)
          where
            readRawMessage :: BSL.ByteString -> IO (BSL.ByteString, BSL.ByteString)
            readRawMessage x
              | fromIntegral (BSL.length x) >= len = return $ BSL.splitAt (fromIntegral len) x
              | otherwise = readRawMessage . BSL.append x . BSL.fromStrict =<< receiveThrowing
            processHeader :: MetaProtocolMessageHeader -> IO MessageHeaderResult
            processHeader CreateChannel = undefined
        handleMetaMessage (SwitchChannel channelId) = liftIO $ modifyMVar_ worker.stateMVar $ \state -> return state{receiveChannel=channelId}
        handleMetaMessage x = liftIO $ print x >> undefined -- Unhandled meta message
        receiveThrowing :: IO BS.ByteString
        receiveThrowing = readMVar worker.stateMVar <&> (.socketConnection) >>= \case
          Just connection -> connection.receive
          Nothing -> throwIO ConnectionIsClosed

metaSend :: MetaProtocolWorker -> MetaProtocolMessage -> IO ()
metaSend worker msg = withMVar worker.stateMVar $ \state -> metaStateSend state msg

metaStateSend :: MetaProtocolWorkerState -> MetaProtocolMessage -> IO ()
metaStateSend state = metaStateSendRaw state . encode

metaStateSendRaw :: MetaProtocolWorkerState -> BSL.ByteString -> IO ()
metaStateSendRaw MetaProtocolWorkerState{socketConnection=Just connection} rawMsg = connection.send rawMsg
metaStateSendRaw MetaProtocolWorkerState{socketConnection=Nothing} _ = undefined

metaSendChannelMessage :: MetaProtocolWorker -> ChannelId -> BSL.ByteString -> [MessageHeader] -> IO ()
metaSendChannelMessage worker channelId msg headers = do
  -- Sending a channel message consists of multiple low-level send operations, so the MVar is held during the operation
  modifyMVar_ worker.stateMVar $ \state -> do
    -- Switch to the specified channel (if required)
    when (state.sendChannel /= channelId) $ metaSend worker (SwitchChannel channelId)

    headerMessages <- sequence (prepareHeader <$> headers)
    metaStateSend state (ChannelMessage headerMessages (fromIntegral (BSL.length msg)))
    metaStateSendRaw state msg
    return state{sendChannel=channelId}
  where
    prepareHeader :: MessageHeader -> IO MetaProtocolMessageHeader
    prepareHeader (CreateChannelHeader newChannelCallback) = undefined


metaChannelClose :: MetaProtocolWorker -> ChannelId -> IO ()
metaChannelClose = undefined

metaClose :: MetaProtocolWorker -> IO ()
metaClose worker = do
  modifyMVar_ worker.stateMVar $ \state -> do
    case state.socketConnection of
      Just connection -> connection.close
      Nothing -> return ()
    return state{socketConnection = Nothing}
  cancel worker.receiveTask


reportProtocolError :: HasMetaProtocolWorker a => a -> String -> IO b
reportProtocolError hasWorker message = do
  let worker = getMetaProtocolWorker hasWorker
  modifyMVar_ worker.stateMVar $ \state -> do
    metaStateSend state $ ProtocolError message
    return state
  -- TODO custom error type, close connection
  undefined

reportLocalError :: HasMetaProtocolWorker a => a -> String -> IO b
reportLocalError hasWorker message = do
  hPutStrLn stderr message
  let worker = getMetaProtocolWorker hasWorker
  modifyMVar_ worker.stateMVar $ \state -> do
    metaStateSend state $ ProtocolError "Internal server error"
    return state
  -- TODO custom error type, close connection
  undefined

data Channel = Channel {
  channelId :: ChannelId,
  worker :: MetaProtocolWorker,
  sendStateMVar :: MVar ChannelSendState,
  receiveStateMVar :: MVar ChannelReceiveState
}
instance HasMetaProtocolWorker Channel where
  getMetaProtocolWorker = (.worker)
newtype ChannelSendState = ChannelSendState {
  nextMessageId :: MessageId
}
data ChannelReceiveState = ChannelReceiveState {
  nextMessageId :: MessageId,
  handler :: ChannelMessageHandler
}
type ChannelMessageHandler = MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()

newChannel :: MetaProtocolWorker -> ChannelId -> IO Channel
newChannel worker channelId = do
  sendStateMVar <- newMVar ChannelSendState {
    nextMessageId = 0
  }
  let handler = (\_ _ _ -> reportLocalError worker ("Channel " <> show channelId <> ": Received message but no Handler is registered"))
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
  -- TODO verify that channelId is not already used (only required if newChannel is exported)
  modifyMVar_ worker.stateMVar $ \state -> return state{channels = HM.insert channelId channel state.channels}
  return channel
channelSend :: Channel -> BSL.ByteString -> [MessageHeader] -> (MessageId -> IO ()) -> IO ()
channelSend channel msg headers callback = do
  modifyMVar_ channel.sendStateMVar $ \state -> do
    callback state.nextMessageId
    metaSendChannelMessage channel.worker channel.channelId msg headers
    return state{nextMessageId = state.nextMessageId + 1}
channelSend_ :: Channel -> BSL.ByteString -> [MessageHeader] -> IO ()
channelSend_ channel msg headers = channelSend channel msg headers (const (return ()))
channelClose :: Channel -> IO ()
channelClose = undefined
channelHandleMessage :: Channel -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
channelHandleMessage channel headers msg = modifyMVar_ channel.receiveStateMVar $ \state -> do
  state.handler state.nextMessageId headers msg
  return state{nextMessageId = state.nextMessageId + 1}
channelSetHandler :: Channel -> ChannelMessageHandler -> IO ()
channelSetHandler channel handler = modifyMVar_ channel.receiveStateMVar $ \state -> return state{handler}


class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleMessage :: ProtocolImpl p -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))


data Client p = Client {
  channel :: Channel,
  stateMVar :: MVar (ClientState p)
}
instance HasMetaProtocolWorker (Client p) where
  getMetaProtocolWorker = (.channel.worker)
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
      \state -> return state{callbacks = HM.insert msgId (requestCompletedCallback resultMVar msgId) state.callbacks}
  -- Block on resultMVar until the request completes
  -- TODO: Future-based variant
  takeMVar resultMVar
  where
    requestCompletedCallback :: MVar (ProtocolResponse p) -> MessageId -> ProtocolResponse p -> IO ()
    requestCompletedCallback resultMVar msgId response = do
      -- Remove callback
      modifyMVar_ client.stateMVar $ \state -> return state{callbacks = HM.delete msgId state.callbacks}
      putMVar resultMVar response
clientHandleChannelMessage :: forall p. (RpcProtocol p) => Client p -> MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
clientHandleChannelMessage client _msgId headers msg = case decodeOrFail msg of
  Left (_, _, errMsg) -> reportProtocolError client errMsg
  Right ("", _, resp) -> clientHandleResponse resp
  Right (leftovers, _, _) -> reportProtocolError client ("Response parser returned unexpected leftovers: " <> show (BSL.length leftovers))
  where
    clientHandleResponse :: (ProtocolResponseWrapper p) -> IO ()
    clientHandleResponse (requestId, resp) = do
      callback <- modifyMVar client.stateMVar $ \state -> do
        let (callbacks, mCallback) = lookupDelete requestId state.callbacks
        case mCallback of
          Just callback -> return (state{callbacks}, callback)
          Nothing -> reportProtocolError client ("Received response with invalid request id " <> show requestId)
      callback resp


data Server p = (RpcProtocol p, HasProtocolImpl p) => Server {
  channel :: Channel,
  protocolImpl :: ProtocolImpl p
}
instance HasMetaProtocolWorker (Server p) where
  getMetaProtocolWorker = (.channel.worker)
serverHandleChannelMessage :: forall p. (RpcProtocol p, HasProtocolImpl p) => Server p -> MessageId -> [MessageHeaderResult] -> BSL.ByteString -> IO ()
serverHandleChannelMessage server msgId headers msg = case decodeOrFail msg of
    Left (_, _, errMsg) -> reportProtocolError server errMsg
    Right ("", _, req) -> serverHandleChannelRequest req
    Right (leftovers, _, _) -> reportProtocolError server ("Request parser returned unexpected leftovers: " <> show (BSL.length leftovers))
  where
    serverHandleChannelRequest :: ProtocolRequest p -> IO ()
    serverHandleChannelRequest req = handleMessage @p server.protocolImpl req >>= maybe (return ()) serverSendResponse
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSend_ server.channel (encode wrappedResponse) []
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (msgId, response)

data Future a
data Sink a
data Source a

-- ** Running client and server

runServerTCP :: RpcProtocol p => ProtocolImpl p -> IO (Server p)
runServerTCP = undefined

runServerUnix :: RpcProtocol p => ProtocolImpl p -> IO (Server p)
runServerUnix = undefined

runClientTCP :: forall p. RpcProtocol p => IO (Client p)
runClientTCP = undefined

runClientUnix :: RpcProtocol p => FilePath -> IO (Client p)
runClientUnix = undefined

newClient :: (IsSocketConnection a, RpcProtocol p) => a -> IO (Client p)
newClient = newChannelClient <=< newMetaProtocolWorker . toSocketConnection

newChannelClient :: RpcProtocol p => Channel -> IO (Client p)
newChannelClient channel = do
  stateMVar <- newMVar emptyClientState
  let client = Client {
    channel,
    stateMVar
  }
  channelSetHandler channel (clientHandleChannelMessage client)
  return client

newServer :: (IsSocketConnection a, RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> a -> IO (Server p)
newServer protocolImpl = newChannelServer protocolImpl <=< newMetaProtocolWorker . toSocketConnection

newChannelServer :: (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> IO (Server p)
newChannelServer protocolImpl channel = do
  let server = Server {
    channel,
    protocolImpl
  }
  channelSetHandler channel (serverHandleChannelMessage server)
  return server

-- ** Test implementation

newDummyClientServer :: (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> IO (Client p, Server p)
newDummyClientServer impl = do
  (clientSocket, serverSocket) <- newDummySocketPair
  client <- newClient clientSocket
  server <- newServer impl serverSocket
  return (client, server)

newDummySocketPair :: IO (SocketConnection, SocketConnection)
newDummySocketPair = do
  upstream <- newEmptyMVar
  downstream <- newEmptyMVar
  let x = SocketConnection {
    send=putMVar upstream . BSL.toStrict,
    receive=takeMVar downstream,
    close=return ()
  }
  let y = SocketConnection {
    send=putMVar downstream . BSL.toStrict,
    receive=takeMVar upstream,
    close=return ()
  }
  return (x, y)


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
    buildTupleType' fs = return $ go (TupleT (length fs)) fs
    go :: Type -> [Type] -> Type
    go t [] = t
    go t (f:fs) = go (AppT t f) fs

buildFunctionType :: Q [Type] -> Q Type -> Q Type
buildFunctionType argTypes returnType = go =<< argTypes
  where
    go :: [Type] -> Q Type
    go [] = returnType
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
    fn = HM.alterF (\c -> State.put c >> return Nothing) key m
