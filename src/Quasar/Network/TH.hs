module Quasar.Network.TH (
  RpcApi,
  RpcFunction,
  RpcArgument,
  RpcResult,
  RpcStream,
  rpcApi,
  rpcFunction,
  addArgument,
  addResult,
  addStream,
  setFixedHandler,
  makeRpc,
  -- TODO: re-add functions that generate only client and server later
  RpcProtocol(ProtocolRequest, ProtocolResponse),
  HasProtocolImpl
) where

import Control.Applicative (liftA2)
import Control.Monad (unless)
import Control.Monad.State (State, execState)
import qualified Control.Monad.State as State
import Data.Binary (Binary)
import Data.Maybe (isNothing)
import GHC.Generics
import Language.Haskell.TH hiding (interruptible)
import Language.Haskell.TH.Syntax
import Prelude
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime

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
                invalid = match wildP (normalB [|$(varE 'clientReportProtocolError) $clientE "TODO"|]) []

            typedSend :: Q Exp
            typedSend = appTypeE [|clientSend|] (protocolType api)
            typedRequest :: Q Exp
            typedRequest = appTypeE (varE 'clientRequestBlocking) (protocolType api)


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
                        createStream channelName streamName = bindS (varP streamName) [|$(varE 'newStream) $(varE channelName)|]
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

-- * Internal

-- ** Protocol generator helpers

functionArgumentTypes :: RpcFunction -> Q [Type]
functionArgumentTypes fun = sequence $ (.ty) <$> fun.arguments
functionResultTypes :: RpcFunction -> Q [Type]
functionResultTypes fun = sequence $ (.ty) <$> fun.results

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
