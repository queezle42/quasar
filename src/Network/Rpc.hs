module Network.Rpc where

import Control.Applicative (liftA2)
import Control.Concurrent (forkFinally)
import Control.Concurrent.Async (cancel, link, withAsync, mapConcurrently_)
import Control.Exception (SomeException, bracket, bracketOnError, bracketOnError, interruptible, mask_)
import Control.Monad (when, unless, forever, void)
import Control.Monad.State (State, execState)
import qualified Control.Monad.State as State
import Control.Concurrent.MVar
import Data.Binary (Binary, encode, decodeOrFail)
import qualified Data.ByteString.Lazy as BSL
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.Maybe (isNothing)
import GHC.Generics
import Language.Haskell.TH hiding (interruptible)
import Language.Haskell.TH.Syntax
import Network.Rpc.Multiplexer
import Network.Rpc.Connection
import qualified Network.Socket as Socket
import Prelude
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)

-- * Rpc api definition

data RpcApi = RpcApi {
  name :: String,
  functions :: [ RpcFunction ]
}

data RpcFunction = RpcFunction {
  name :: String,
  arguments :: [RpcArgument],
  results :: [RpcResult],
  streams :: [RpcStream],
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

data RpcStream = RpcStream {
  name :: String,
  tyUp :: Q Type,
  tyDown :: Q Type
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
    streams = [],
    fixedHandler = Nothing
  }

addArgument :: String -> Q Type -> State RpcFunction ()
addArgument name t = State.modify (\fun -> fun{arguments = fun.arguments <> [RpcArgument name t]})

addResult :: String -> Q Type -> State RpcFunction ()
addResult name t = State.modify (\fun -> fun{results = fun.results <> [RpcResult name t]})

addStream :: String -> Q Type -> Q Type -> State RpcFunction ()
addStream name tUp tDown = State.modify (\fun -> fun{streams = fun.streams <> [RpcStream name tUp tDown]})

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
      argNames <- sequence (newName . (.name) <$> fun.arguments)
      channelNames <- sequence (newName . (<> "Channel") . (.name) <$> fun.streams)
      streamNames <- sequence (newName . (.name) <$> fun.streams)
      makeClientFunction' clientVarName argNames channelNames streamNames
      where
        funName :: Name
        funName = mkName fun.name
        makeClientFunction' :: Name -> [Name] -> [Name] -> [Name] -> Q [Dec]
        makeClientFunction' clientVarName argNames channelNames streamNames = do
          funArgTypes <- functionArgumentTypes fun
          clientType <- [t|Client $(protocolType api)|]
          resultType <- optionalResultType
          streamTypes <- clientStreamTypes
          sequence [
            sigD funName (buildFunctionType (pure ([clientType] <> funArgTypes)) [t|IO $(buildTupleType (pure (resultType <> streamTypes)))|]),
            funD funName [clause ([varP clientVarName] <> varPats) body []]
            ]
          where
            optionalResultType :: Q [Type]
            optionalResultType
              | hasResult fun = (\x -> [x]) <$> buildTupleType (functionResultTypes fun)
              | otherwise = pure []
            clientStreamTypes :: Q [Type]
            clientStreamTypes = sequence $ (\stream -> [t|Stream $(stream.tyUp) $(stream.tyDown)|]) <$> fun.streams
            clientE :: Q Exp
            clientE = varE clientVarName
            varPats :: [Q Pat]
            varPats = varP <$> argNames
            body :: Q Body
            body
              | hasResult fun = normalB $ doE $
                  [
                    bindS [p|(response, resources)|] (requestE requestDataE),
                    bindS [p|result|] (checkResult [|response|])
                  ] <>
                  createStreams [|resources.createdChannels|] <>
                  [noBindS [|pure $(buildTuple (liftA2 (:) [|result|] streamsE))|]]
              | otherwise = normalB $ doE $
                  [bindS [p|resources|] (sendE requestDataE)] <>
                  createStreams [|resources.createdChannels|] <>
                  [noBindS [|pure $(buildTuple streamsE)|]]
            requestDataE :: Q Exp
            requestDataE = applyVars (conE (requestFunctionCtorName api fun))
            createStreams :: Q Exp -> [Q Stmt]
            createStreams channelsE = if length fun.streams > 0 then [assignChannels] <> go channelNames streamNames else [verifyNoChannels]
              where
                verifyNoChannels :: Q Stmt
                verifyNoChannels = noBindS [|unless (null $(channelsE)) (fail "Invalid number of channel created")|]
                assignChannels :: Q Stmt
                assignChannels =
                  bindS
                    (tupP (varP <$> channelNames))
                    $ caseE channelsE [
                      match (listP (varP <$> channelNames)) (normalB [|pure $(tupE (varE <$> channelNames))|]) [],
                      match [p|_|] (normalB [|fail "Invalid number of channel created"|]) []
                      ]
                go :: [Name] -> [Name] -> [Q Stmt]
                go [] [] = []
                go (cn:cns) (sn:sns) = createStream cn sn : go cns sns
                go _ _ = fail "Logic error: lists have different lengths"
                createStream :: Name -> Name -> Q Stmt
                createStream channelName streamName = bindS (varP streamName) [|newStream $(varE channelName)|]
            streamsE :: Q [Exp]
            streamsE = mapM varE streamNames
            messageConfigurationE :: Q Exp
            messageConfigurationE = [|defaultMessageConfiguration{createChannels = $(litE $ integerL $ toInteger $ length fun.streams)}|]
            sendE :: Q Exp -> Q Exp
            sendE msgExp = [|$typedSend $clientE $messageConfigurationE $msgExp|]
            requestE :: Q Exp -> Q Exp
            requestE msgExp = [|$typedRequest $clientE $messageConfigurationE $msgExp|]
            applyVars :: Q Exp -> Q Exp
            applyVars = go argNames
              where
                go :: [Name] -> Q Exp -> Q Exp
                go [] ex = ex
                go (n:ns) ex = go ns (appE ex (varE n))
            -- check if the response to a request matches the expected result constructor
            checkResult :: Q Exp -> Q Exp
            checkResult x = caseE x [valid, invalid]
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
    handlerFunctionType fun = do
      argumentTypes <- functionArgumentTypes fun
      streamTypes <- serverStreamTypes
      buildFunctionType (pure (argumentTypes <> streamTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]
      where
        serverStreamTypes :: Q [Type]
        serverStreamTypes = sequence $ (\stream -> [t|Stream $(stream.tyDown) $(stream.tyUp)|]) <$> fun.streams

    logicInstanceDec :: Q Dec
    logicInstanceDec = instanceD (cxt []) [t|HasProtocolImpl $(protocolType api)|] [
      tySynInstD (tySynEqn Nothing [t|ProtocolImpl $(protocolType api)|] (implType api)),
      messageHandler
      ]
    messageHandler :: Q Dec
    messageHandler = do
      handleMessagePrimeName <- newName "handleMessage"
      implName <- newName "impl"
      channelsName <- newName "channels"
      funD 'handleMessage [clause [varP implName, varP channelsName] (normalB (varE handleMessagePrimeName)) [handleMessagePrimeDec handleMessagePrimeName (varE implName) (varE channelsName)]]
      where
        handleMessagePrimeDec :: Name -> Q Exp -> Q Exp -> Q Dec
        handleMessagePrimeDec handleMessagePrimeName implE channelsE = funD handleMessagePrimeName (handlerFunctionClause <$> functions)
          where
            handlerFunctionClause :: RpcFunction -> Q Clause
            handlerFunctionClause fun = do
              argNames <- sequence (newName . (.name) <$> fun.arguments)
              channelNames <- sequence (newName . (<> "Channel") . (.name) <$> fun.streams)
              streamNames <- sequence (newName . (.name) <$> fun.streams)
              serverLogicHandlerFunctionClause' argNames channelNames streamNames
              where
                serverLogicHandlerFunctionClause' :: [Name] -> [Name] -> [Name] -> Q Clause
                serverLogicHandlerFunctionClause' argNames channelNames streamNames = clause [conP (requestFunctionCtorName api fun) varPats] body []
                  where
                    varPats :: [Q Pat]
                    varPats = varP <$> argNames
                    body :: Q Body
                    body = normalB $ doE $ createStreams <> [callImplementation]
                    createStreams :: [Q Stmt]
                    createStreams = if length fun.streams > 0 then [assignChannels] <> go channelNames streamNames else [verifyNoChannels]
                      where
                        verifyNoChannels :: Q Stmt
                        verifyNoChannels = noBindS [|unless (null $(channelsE)) (fail "Received invalid channel count")|] -- TODO channelReportProtocolError
                        assignChannels :: Q Stmt
                        assignChannels =
                          bindS
                            (tupP (varP <$> channelNames))
                            $ caseE channelsE [
                              match (listP (varP <$> channelNames)) (normalB [|pure $(tupE (varE <$> channelNames))|]) [],
                              match [p|_|] (normalB [|fail "Received invalid channel count"|]) [] -- TODO channelReportProtocolError
                              ]
                        go :: [Name] -> [Name] -> [Q Stmt]
                        go [] [] = []
                        go (cn:cns) (sn:sns) = createStream cn sn : go cns sns
                        go _ _ = fail "Logic error: lists have different lengths"
                        createStream :: Name -> Name -> Q Stmt
                        createStream channelName streamName = bindS (varP streamName) [|newStream $(varE channelName)|]
                    callImplementation :: Q Stmt
                    callImplementation = noBindS callImplementationE
                    callImplementationE :: Q Exp
                    callImplementationE
                      | hasResult fun = [|Just <$> $(packResponse (applyStreams (applyArguments implExp)))|]
                      | otherwise = [|Nothing <$ $(applyStreams (applyArguments implExp))|]
                    packResponse :: Q Exp -> Q Exp
                    packResponse = fmapE (conE (responseFunctionCtorName api fun))
                    applyArguments :: Q Exp -> Q Exp
                    applyArguments = go argNames
                      where
                        go :: [Name] -> Q Exp -> Q Exp
                        go [] ex = ex
                        go (n:ns) ex = go ns (appE ex (varE n))
                    applyStreams :: Q Exp -> Q Exp
                    applyStreams = go streamNames
                      where
                        go :: [Name] -> Q Exp -> Q Exp
                        go [] ex = ex
                        go (sn:sns) ex = go sns (appE ex (varE sn))
                    implExp :: Q Exp
                    implExp = implExp' fun.fixedHandler
                      where
                        implExp' :: Maybe (Q Exp) -> Q Exp
                        implExp' Nothing = varE (implFieldName api fun) `appE` implE
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
  handleMessage :: ProtocolImpl p -> [Channel] -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))


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

clientSend :: RpcProtocol p => Client p -> MessageConfiguration -> ProtocolRequest p -> IO SentMessageResources
clientSend client config req = channelSend_ client.channel config (encode req)
clientRequestBlocking :: forall p. RpcProtocol p => Client p -> MessageConfiguration -> ProtocolRequest p -> IO (ProtocolResponse p, SentMessageResources)
clientRequestBlocking client config req = do
  resultMVar <- newEmptyMVar
  sentMessageResources <- channelSend client.channel config (encode req) $ \msgId ->
    modifyMVar_ client.stateMVar $
      \state -> pure state{callbacks = HM.insert msgId (requestCompletedCallback resultMVar msgId) state.callbacks}
  -- Block on resultMVar until the request completes
  -- TODO: Future-based variant
  result <- takeMVar resultMVar
  pure (result, sentMessageResources)
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
      unless (null resources.createdChannels) (channelReportProtocolError client.channel "Received unexpected new channel during a rpc response")
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
    Right ("", _, req) -> serverHandleChannelRequest resources.createdChannels req
    Right (leftovers, _, _) -> channelReportProtocolError channel ("Request parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    serverHandleChannelRequest :: [Channel] -> ProtocolRequest p -> IO ()
    serverHandleChannelRequest channels req = handleMessage @p protocolImpl channels req >>= maybe (pure ()) serverSendResponse
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSendSimple channel (encode wrappedResponse)
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (resources.messageId, response)

registerChannelServerHandler :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> IO ()
registerChannelServerHandler protocolImpl channel = channelSetHandler channel (serverHandleChannelMessage @p protocolImpl channel)


newtype Stream up down = Stream Channel

newStream :: Channel -> IO (Stream up down)
newStream = pure . Stream

streamSend :: Binary up => Stream up down -> up -> IO ()
streamSend (Stream channel) value = channelSendSimple channel (encode value)

streamSetHandler :: Binary down => Stream up down -> (down -> IO ()) -> IO ()
streamSetHandler (Stream channel) handler = channelSetSimpleHandler channel handler

streamClose :: Stream up down -> IO ()
streamClose (Stream channel) = channelClose channel

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

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

data Server p = Server {
  protocolImpl :: ProtocolImpl p
}

-- | Internal
newServer :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> IO (Server p)
newServer protocolImpl = pure Server { protocolImpl }

-- | Internal
execServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> [Listener] -> IO a
execServer server listeners = mapConcurrently_ runListener listeners >> fail "Server failed: All listeners stopped unexpectedly"
  where
    runListener :: Listener -> IO ()
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

runServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> [Listener] -> IO a
runServer _ [] = fail "Tried to start a server without any listeners attached"
runServer protocolImpl listener = do
  server <- newServer @p protocolImpl
  execServer server listener

withServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> [Listener] -> (Server p -> IO a) -> IO a
withServer protocolImpl [] action = action =<< newServer @p protocolImpl
withServer protocolImpl listeners action = do
  server <- newServer @p protocolImpl
  withAsync (execServer server listeners) (\x -> link x >> action server <* cancel x)

listenTCP :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> IO a
listenTCP impl mhost port = runServer @p impl [TcpPort mhost port]

-- | Internal
runTCPListener :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> Maybe Socket.HostName -> Socket.ServiceName -> IO a
runTCPListener server mhost port = do
  addr <- resolve
  bracket (open addr) Socket.close (runListenerOnBoundSocket server)
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

listenUnix :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> FilePath -> IO a
listenUnix impl path = runServer @p impl [UnixSocket path]

runUnixSocketListener :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> FilePath -> IO a
runUnixSocketListener server socketPath = do
  bracket create Socket.close (runListenerOnBoundSocket server)
  where
    create :: IO Socket.Socket
    create = do
      fileExistsAtPath <- fileExist socketPath
      when fileExistsAtPath $ do
        fileStatus <- getFileStatus socketPath
        if isSocket fileStatus
          then removeLink socketPath
          else fail "Cannot bind socket: Socket path is not empty"

      bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.bind sock (Socket.SockAddrUnix socketPath)
        pure sock

-- | Listen and accept connections on an already bound socket.
listenOnBoundSocket :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Socket.Socket -> IO a
listenOnBoundSocket protocolImpl socket = runServer @p protocolImpl [ListenSocket socket]

-- | Internal
runListenerOnBoundSocket :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> Socket.Socket -> IO a
runListenerOnBoundSocket server sock = do
  Socket.listen sock 1024
  forever $ mask_ $ do
    (conn, _sockAddr) <- Socket.accept sock
    connectToServer server conn

-- | Internal
connectToServer :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsConnection a) => Server p -> a -> IO ()
connectToServer server conn = void $ forkFinally (interruptible (runServerHandler @p server.protocolImpl connection)) socketFinalization
  where
    connection :: Connection
    connection = toSocketConnection conn
    socketFinalization :: Either SomeException () -> IO ()
    socketFinalization (Left _err) = do
      -- TODO: log error
      --logStderr $ "Client connection closed with error " <> show err
      connection.close
    socketFinalization (Right ()) = do
      connection.close

-- | Internal
runServerHandler :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsConnection a) => ProtocolImpl p -> a -> IO ()
runServerHandler protocolImpl = runMultiplexer MultiplexerSideB (registerChannelServerHandler @p protocolImpl) . toSocketConnection


withLocalClient :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> ((Client p) -> IO a) -> IO a
withLocalClient server = bracket (newLocalClient server) clientClose

newLocalClient :: forall p. (RpcProtocol p, HasProtocolImpl p) => Server p -> IO (Client p)
newLocalClient server = do
  unless Socket.isUnixDomainSocketAvailable $ fail "Unix domain sockets are not available"
  mask_ $ do
    (clientSocket, serverSocket) <- Socket.socketPair Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    connectToServer server serverSocket
    newClient @p clientSocket

-- ** Test implementation

withStandaloneClient :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> (Client p -> IO a) -> IO a
withStandaloneClient impl runClientHook = withServer impl [] $ \server -> withLocalClient server runClientHook


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
    buildTupleType' [] = [t|()|]
    buildTupleType' [single] = pure single
    buildTupleType' fs = pure $ go (TupleT (length fs)) fs
    go :: Type -> [Type] -> Type
    go t [] = t
    go t (f:fs) = go (AppT t f) fs

buildTuple :: Q [Exp] -> Q Exp
buildTuple fields = buildTuple' =<< fields
  where
    buildTuple' :: [Exp] -> Q Exp
    buildTuple' [] = [|()|]
    buildTuple' [single] = pure single
    buildTuple' fs = pure $ TupE (Just <$> fs)

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
fmapE f e = [|$(f) <$> $(e)|]

-- ** General helper functions

-- | Lookup and delete a value from a HashMap in one operation
lookupDelete :: forall k v. (Eq k, Hashable k) => k -> HM.HashMap k v -> (HM.HashMap k v, Maybe v)
lookupDelete key m = State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (HM.HashMap k v)
    fn = HM.alterF (\c -> State.put c >> pure Nothing) key m
