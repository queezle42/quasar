module Network.Rpc where

import Control.Concurrent (forkFinally)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (SomeException, bracket, bracketOnError, bracketOnError)
import Control.Monad (when, unless, forever, void)
import Control.Monad.State (State, execState)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode, decodeOrFail)
import qualified Data.ByteString.Lazy as BSL
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.Maybe (isNothing)
import Language.Haskell.TH hiding (interruptible)
import Language.Haskell.TH.Syntax
import Network.Rpc.Multiplexer
import Network.Rpc.Connection
import qualified Network.Socket as Socket
import Prelude
import GHC.Generics
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
                invalid = match wildP (normalB [|clientReportProtocolError $clientE "TODO"|]) []

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

class (Binary (ProtocolRequest p), Binary (ProtocolResponse p)) => RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p

type ProtocolResponseWrapper p = (MessageId, ProtocolResponse p)

class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleMessage :: ProtocolImpl p -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))


data Client p = Client {
  channel :: Channel,
  stateMVar :: MVar (ClientState p)
}
newtype ClientState p = ClientState {
  callbacks :: HM.HashMap MessageId (ProtocolResponse p -> IO ())
}
emptyClientState :: ClientState p
emptyClientState = ClientState {
  callbacks = HM.empty
}

clientSend :: RpcProtocol p => Client p -> ProtocolRequest p -> IO ()
clientSend client req = void $ channelSend_ client.channel [] (encode req)
clientRequestBlocking :: forall p. RpcProtocol p => Client p -> ProtocolRequest p -> IO (ProtocolResponse p)
clientRequestBlocking client req = do
  resultMVar <- newEmptyMVar
  void $ channelSend client.channel [] (encode req) $ \msgId ->
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
clientHandleChannelMessage :: forall p. (RpcProtocol p) => Client p -> ReceivedMessageResources -> BSL.ByteString -> IO ()
clientHandleChannelMessage client resources msg = case decodeOrFail msg of
  Left (_, _, errMsg) -> channelReportProtocolError client.channel errMsg
  Right ("", _, resp) -> clientHandleResponse resp
  Right (leftovers, _, _) -> channelReportProtocolError client.channel ("Response parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    clientHandleResponse :: ProtocolResponseWrapper p -> IO ()
    clientHandleResponse (requestId, resp) = do
      mapM_ undefined resources.createdChannels
      callback <- modifyMVar client.stateMVar $ \state -> do
        let (callbacks, mCallback) = lookupDelete requestId state.callbacks
        case mCallback of
          Just callback -> pure (state{callbacks}, callback)
          Nothing -> channelReportProtocolError client.channel ("Received response with invalid request id " <> show requestId)
      callback resp

clientClose :: Client p -> IO ()
clientClose client = channelClose client.channel

clientReportProtocolError :: Client p -> String -> IO a
clientReportProtocolError client = channelReportProtocolError client.channel


serverHandleChannelMessage :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> ReceivedMessageResources -> BSL.ByteString -> IO ()
serverHandleChannelMessage protocolImpl channel resources msg = case decodeOrFail msg of
    Left (_, _, errMsg) -> channelReportProtocolError channel errMsg
    Right ("", _, req) -> serverHandleChannelRequest req
    Right (leftovers, _, _) -> channelReportProtocolError channel ("Request parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    serverHandleChannelRequest :: ProtocolRequest p -> IO ()
    serverHandleChannelRequest req = handleMessage @p protocolImpl req >>= maybe (pure ()) serverSendResponse
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSendSimple channel (encode wrappedResponse)
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (resources.messageId, response)

registerChannelServerHandler :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> IO ()
registerChannelServerHandler protocolImpl channel = channelSetHandler channel (serverHandleChannelMessage @p protocolImpl channel)


-- ** Running client and server

withClientTCP :: RpcProtocol p => Socket.HostName -> Socket.ServiceName -> (Client p -> IO a) -> IO a
withClientTCP host port = bracket (newClientTCP host port) clientClose

newClientTCP :: forall p. RpcProtocol p => Socket.HostName -> Socket.ServiceName -> IO (Client p)
newClientTCP host port = newClient =<< connectTCP host port


withClientUnix :: RpcProtocol p => FilePath -> (Client p -> IO a) -> IO a
withClientUnix socketPath = bracket (newClientUnix socketPath) clientClose

newClientUnix :: RpcProtocol p => FilePath -> IO (Client p)
newClientUnix socketPath = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
  Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
  Socket.connect sock $ Socket.SockAddrUnix socketPath
  newClient sock


withClient :: forall p a b. (IsConnection a, RpcProtocol p) => a -> (Client p -> IO b) -> IO b
withClient x = bracket (newClient x) clientClose

newClient :: forall p a. (IsConnection a, RpcProtocol p) => a -> IO (Client p)
newClient x = newChannelClient =<< newMultiplexer MultiplexerSideA (toSocketConnection x)


newChannelClient :: RpcProtocol p => Channel -> IO (Client p)
newChannelClient channel = do
  stateMVar <- newMVar emptyClientState
  let client = Client {
    channel,
    stateMVar
  }
  channelSetHandler channel (clientHandleChannelMessage client)
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

runServerHandler :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsConnection a) => ProtocolImpl p -> a -> IO ()
runServerHandler protocolImpl = runMultiplexer MultiplexerSideB (registerChannelServerHandler @p protocolImpl) . toSocketConnection


-- ** Test implementation

withDummyClientServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> (Client p -> IO a) -> IO a
withDummyClientServer impl runClientHook = do
  unless Socket.isUnixDomainSocketAvailable $ fail "Unix domain sockets are not available"
  (clientSocket, serverSocket) <- Socket.socketPair Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
  withAsync (runServerHandler @p impl serverSocket) $ \serverTask -> do
    link serverTask
    withClient clientSocket runClientHook


-- * Internal

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
    fn = HM.alterF (\c -> State.put c >> pure Nothing) key m
