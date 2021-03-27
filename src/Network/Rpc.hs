{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Network.Rpc where

import Control.Monad.State as State
import Data.Binary (Binary)
import Data.Maybe (isNothing)
import Data.Word
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Lens.Micro
import Lens.Micro.Mtl
import Lens.Micro.TH
import Network.Rpc.Utils
import Prelude
import GHC.Generics

-- * Rpc api definition

data RpcApi = RpcApi {
  rpcApiName :: String,
  rpcApiFunctions :: [ RpcFunction ]
}

data RpcFunction = RpcFunction {
  _rpcFunctionName :: String,
  _rpcFunctionArguments :: [RpcArgument],
  _rpcFunctionResults :: [RpcResult],
  _rpcFunctionFixedHandler :: Maybe (Q Exp)
}

data RpcArgument = RpcArgument {
  _rpcArgumentName :: String,
  _rpcArgumentType :: Q Type
}

data RpcResult = RpcResult {
  _rpcResultName :: String,
  _rpcResultType :: Q Type
}

$(makeLenses ''RpcFunction)
$(makeLenses ''RpcArgument)
$(makeLenses ''RpcResult)

rpcApi :: String -> [RpcFunction] -> RpcApi
rpcApi apiName functions = RpcApi {
  rpcApiName = apiName,
  rpcApiFunctions = functions
}

rpcFunction :: String -> State RpcFunction () -> RpcFunction
rpcFunction methodName setup = execState setup RpcFunction {
    _rpcFunctionName = methodName,
    _rpcFunctionArguments = [],
    _rpcFunctionResults = [],
    _rpcFunctionFixedHandler = Nothing
  }

addArgument :: String -> Q Type -> State RpcFunction ()
addArgument name t = rpcFunctionArguments <>= [RpcArgument name t]

addResult :: String -> Q Type -> State RpcFunction ()
addResult name t = rpcFunctionResults <>= [RpcResult name t]

setFixedHandler :: Q Exp -> State RpcFunction ()
setFixedHandler handler = rpcFunctionFixedHandler .= Just handler

-- * Template Haskell rpc protocol generator

makeProtocol :: RpcApi -> Q [Dec]
makeProtocol api@RpcApi{rpcApiFunctions} = sequence [protocolDec, protocolInstanceDec, messageDec, responseDec]
  where
    protocolDec :: Q Dec
    protocolDec = dataD (return []) (protocolTypeName api) [] Nothing [] []

    protocolInstanceDec :: Q Dec
    protocolInstanceDec = instanceD (cxt []) (appT (conT ''RpcProtocol) (protocolType api)) [
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolRequest) (protocolType api)) (conT (requestTypeName api))),
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolResponse) (protocolType api)) (conT (responseTypeName api)))
      ]

    messageDec :: Q Dec
    messageDec = dataD (return []) (requestTypeName api) [] Nothing (messageCon <$> rpcApiFunctions) serializableTypeDerivClauses
      where
        messageCon :: RpcFunction -> Q Con
        messageCon fun = normalC (requestFunctionCtorName api fun) (messageConVar <$> fun ^. rpcFunctionArguments)
          where
            messageConVar :: RpcArgument -> Q BangType
            messageConVar (RpcArgument _name ty) = defaultBangType ty

    responseDec :: Q Dec
    responseDec = dataD (return []) (responseTypeName api) [] Nothing (responseCon <$> rpcApiFunctions) serializableTypeDerivClauses
      where
        responseCon :: RpcFunction -> Q Con
        responseCon fun = normalC (responseFunctionCtorName api fun) [defaultBangType (resultTupleType fun)]
        resultTupleType :: RpcFunction -> Q Type
        resultTupleType fun = buildTupleType (sequence (fun ^.. rpcFunctionResults . each . rpcResultType))

    serializableTypeDerivClauses :: [Q DerivClause]
    serializableTypeDerivClauses = [
      derivClause Nothing [[t|Eq|], [t|Show|], [t|Generic|], [t|Binary|]]
      ]

makeClient :: RpcApi -> Q [Dec]
makeClient api@RpcApi{rpcApiFunctions} = do
  mconcat <$> mapM makeClientFunction rpcApiFunctions
  where
    makeClientFunction :: RpcFunction -> Q [Dec]
    makeClientFunction fun = do
      clientVarName <- newName "client"
      varNames <- sequence (newName <$> (fun ^.. rpcFunctionArguments . each . rpcArgumentName))
      makeClientFunction' clientVarName varNames
      where
        funName :: Name
        funName = mkName (fun ^. rpcFunctionName)
        makeClientFunction' :: Name -> [Name] -> Q [Dec]
        makeClientFunction' clientVarName varNames = do
          funArgTypes <- functionArgumentTypes fun
          clientTypeName <- newName "client"
          clientType <- varT clientTypeName
          let funType = buildFunctionType (return ([clientType] <> funArgTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]
          sequence [
            sigD funName (forallT [plainTV clientTypeName] (cxt [[t|IsClient $(protocolType api) $(return clientType)|]]) funType),
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
                invalid = match wildP (normalB [|$typedReportProtocolError $clientE "foobar"|]) []

            typedSend :: Q Exp
            typedSend = appTypeE [|send|] (protocolType api)
            typedRequest :: Q Exp
            typedRequest = appTypeE [|request|] (protocolType api)
            typedReportProtocolError :: Q Exp
            typedReportProtocolError = appTypeE [|reportProtocolError|] (protocolType api)


makeServer :: RpcApi -> Q [Dec]
makeServer api@RpcApi{rpcApiFunctions} = sequence [handlerRecordDec, logicInstanceDec]
  where
    handlerRecordDec :: Q Dec
    handlerRecordDec = dataD (return []) (implTypeName api) [] Nothing [recC (implTypeName api) (handlerRecordField <$> functionsWithoutBuiltinHandler)] []
    functionsWithoutBuiltinHandler :: [RpcFunction]
    functionsWithoutBuiltinHandler = filter (isNothing . view rpcFunctionFixedHandler) rpcApiFunctions
    handlerRecordField :: RpcFunction -> Q VarBangType
    handlerRecordField fun = varDefaultBangType (implFieldName api fun) (handlerFunctionType fun)
    handlerFunctionType :: RpcFunction -> Q Type
    handlerFunctionType fun = buildFunctionType (functionArgumentTypes fun) [t|IO $(buildTupleType (functionResultTypes fun))|]

    logicInstanceDec :: Q Dec
    logicInstanceDec = instanceD (cxt []) [t|ProtocolHandlerLogic $(protocolType api)|] [
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
        handleMessagePrimeDec handleMessagePrimeName implName = funD handleMessagePrimeName (handlerFunctionClause <$> rpcApiFunctions)
          where
            handlerFunctionClause :: RpcFunction -> Q Clause
            handlerFunctionClause fun = do
              varNames <- sequence (newName <$> (fun ^.. rpcFunctionArguments . each . rpcArgumentName))
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
                    implExp = implExp' (fun ^. rpcFunctionFixedHandler)
                      where
                        implExp' :: Maybe (Q Exp) -> Q Exp
                        implExp' Nothing = varE (implFieldName api fun) `appE` varE implName
                        implExp' (Just handler) = do
                          fixedHandlerName <- newName "impl"
                          letE [
                              sigD fixedHandlerName implSig,
                              valD (varP fixedHandlerName) (normalB handler) []
                            ] (varE fixedHandlerName)
                    implSig :: Q Type
                    implSig = handlerFunctionType fun

-- * Runtime


class RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p



class RpcProtocol p => IsClient p a where
  -- Order of appearence is important for type variables in the class signature, because TypeApplication must be used to specify the protocol. The (RpcProtocol p) contraint always has to stay the first constraint.
  send :: a -> ProtocolRequest p -> IO ()
  request :: a -> ProtocolRequest p -> IO (ProtocolResponse p)
  reportProtocolError :: forall b. a -> String -> IO b

class RpcProtocol p => IsServer p a where
  onMessage :: a -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))

class RpcProtocol p => ProtocolHandlerLogic p where
  type ProtocolImpl p
  handleMessage :: ProtocolImpl p -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))


data Client p = Client {
}
instance RpcProtocol p => IsClient p (Client p) where
  send = undefined
  request = undefined
  reportProtocolError = undefined

data Server p = Server {
  serverProtocolImpl :: ProtocolImpl p
}
instance (RpcProtocol p, ProtocolHandlerLogic p) => IsServer p (Server p) where
  onMessage :: Server p -> ProtocolRequest p -> IO (Maybe (ProtocolResponse p))
  onMessage Server{serverProtocolImpl} = handleMessage @p serverProtocolImpl

data Channel up down = Channel {
}

data Future a
data Sink a
data Source a

type StreamId = Word64
data MetaProtocolMessage
  = ChannelMessage Word64
  | SetChannel StreamId

-- ** Running client and server

runServerTCP :: RpcProtocol a => ProtocolImpl a -> IO (Server a)
runServerTCP = undefined

runServerUnix :: RpcProtocol a => ProtocolImpl a -> IO (Server a)
runServerUnix = undefined

withClientTCP :: RpcProtocol a => IO (Client a)
withClientTCP = undefined

withClientUnix :: RpcProtocol a => IO (Client a)
withClientUnix = undefined

-- ** Test implementation

newtype DummyClient p = DummyClient (ProtocolImpl p)
instance forall p. (RpcProtocol p, ProtocolHandlerLogic p) => IsClient p (DummyClient p) where
  send :: DummyClient p -> ProtocolRequest p -> IO ()
  send (DummyClient impl) req = do
    Nothing <- handleMessage @p impl req
    return ()
  request :: DummyClient p -> ProtocolRequest p -> IO (ProtocolResponse p)
  request (DummyClient impl) req = do
    (Just response) <- handleMessage @p impl req
    return response
  reportProtocolError :: DummyClient p -> String -> IO a
  reportProtocolError _ = fail


-- * Internal
--
-- ** Protocol generator helpers

functionArgumentTypes :: RpcFunction -> Q [Type]
functionArgumentTypes fun = sequence $ fun ^.. rpcFunctionArguments . each . rpcArgumentType
functionResultTypes :: RpcFunction -> Q [Type]
functionResultTypes fun = sequence $ fun ^.. rpcFunctionResults . each . rpcResultType

hasFixedHandler :: RpcFunction -> Bool
hasFixedHandler RpcFunction{_rpcFunctionFixedHandler = Nothing} = False
hasFixedHandler _ = True

hasResult :: RpcFunction -> Bool
hasResult fun = not (null (fun ^. rpcFunctionResults))


-- *** Name helper functions

protocolTypeName :: RpcApi -> Name
protocolTypeName RpcApi{rpcApiName} = mkName (rpcApiName <> "Protocol")

protocolType :: RpcApi -> Q Type
protocolType = conT . protocolTypeName

requestTypeIdentifier :: RpcApi -> String
requestTypeIdentifier RpcApi{rpcApiName} = rpcApiName <> "ProtocolRequest"

requestTypeName :: RpcApi -> Name
requestTypeName = mkName . requestTypeIdentifier

requestFunctionCtorName :: RpcApi -> RpcFunction -> Name
requestFunctionCtorName api fun = mkName (requestTypeIdentifier api <> "_" <> (fun ^. rpcFunctionName))

responseTypeIdentifier :: RpcApi -> String
responseTypeIdentifier RpcApi{rpcApiName} = rpcApiName <> "ProtocolResponse"

responseTypeName :: RpcApi -> Name
responseTypeName = mkName . responseTypeIdentifier

responseFunctionCtorName :: RpcApi -> RpcFunction -> Name
responseFunctionCtorName api fun = mkName (responseTypeIdentifier api <> "_" <> (fun ^. rpcFunctionName))

implTypeName :: RpcApi -> Name
implTypeName RpcApi{rpcApiName} = mkName $ rpcApiName <> "ProtocolImpl"

implType :: RpcApi -> Q Type
implType = conT . implTypeName

implFieldName :: RpcApi -> RpcFunction -> Name
implFieldName _api fun = mkName (fun ^. rpcFunctionName <> "Impl")

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
