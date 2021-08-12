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
  rpcObservable,
  makeRpc,
  -- TODO: re-add functions that generate only client and server later
  RpcProtocol(ProtocolRequest, ProtocolResponse),
  HasProtocolImpl
) where

import Control.Monad.State (State, execState)
import qualified Control.Monad.State as State
import Data.Binary (Binary)
import Data.Maybe (isJust, isNothing)
import GHC.Records.Compat (HasField)
import Language.Haskell.TH hiding (interruptible)
import Language.Haskell.TH.Syntax
import Quasar.Awaitable
import Quasar.Core
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Network.Runtime.Observable
import Quasar.Observable
import Quasar.Prelude

data RpcApi = RpcApi {
  name :: String,
  functions :: [ RpcFunction ],
  observables :: [ RpcObservable ]
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

data RpcObservable = RpcObservable {
  name :: String,
  ty :: Q Type
}

rpcApi :: String -> State RpcApi () -> RpcApi
rpcApi apiName setup = execState setup RpcApi {
  name = apiName,
  functions = [],
  observables = []
}

rpcFunction :: String -> State RpcFunction () -> State RpcApi ()
rpcFunction methodName setup = State.modify (\api -> api{functions = api.functions <> [fun]})
  where
    fun = execState setup RpcFunction {
      name = methodName,
      arguments = [],
      results = [],
      streams = [],
      fixedHandler = Nothing
    }

rpcObservable :: String -> Q Type -> State RpcApi ()
rpcObservable name ty = State.modify (\api -> api{observables = api.observables <> [observable]})
  where
    observable = RpcObservable {
      name,
      ty
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
makeRpc api = do
  code <- mconcat <$> sequence ((generateFunction api <$> api.functions) <> (generateObservable api <$> api.observables))
  mconcat <$> sequence [makeProtocol api code, makeClient api code, makeServer api code]

makeProtocol :: RpcApi -> Code -> Q [Dec]
makeProtocol api code = sequence [protocolDec, protocolInstanceDec, requestDec, responseDec]
  where
    protocolDec :: Q Dec
    protocolDec = dataD (pure []) (protocolTypeName api) [] Nothing [] []

    protocolInstanceDec :: Q Dec
    protocolInstanceDec = instanceD (cxt []) (appT (conT ''RpcProtocol) (protocolType api)) [
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolRequest) (protocolType api)) (conT (requestTypeName api))),
      tySynInstD (tySynEqn Nothing (appT (conT ''ProtocolResponse) (protocolType api)) (conT (responseTypeName api)))
      ]

    requestDec :: Q Dec
    requestDec = dataD (pure []) (requestTypeName api) [] Nothing (requestCon <$> code.requests) serializableTypeDerivClauses
      where
        requestCon :: Request -> Q Con
        requestCon req = normalC (requestConName api req) (defaultBangType . (.ty) <$> req.fields)

    responseDec :: Q Dec
    responseDec = do
      dataD (pure []) (responseTypeName api) [] Nothing (responseCon <$> catMaybes ((.mResponse) <$> code.requests)) serializableTypeDerivClauses
      where
        responseCon :: Response -> Q Con
        responseCon resp = normalC (responseConName api resp) (defaultBangType . (.ty) <$> resp.fields)

    serializableTypeDerivClauses :: [Q DerivClause]
    serializableTypeDerivClauses = [
      derivClause (Just StockStrategy) [[t|Eq|], [t|Show|], [t|Generic|]],
      derivClause (Just AnyclassStrategy) [[t|Binary|]]
      ]

makeClient :: RpcApi -> Code -> Q [Dec]
makeClient api code = do
  requestStubDecs <- mconcat <$> sequence (clientRequestStub api <$> code.requests)
  sequence $ code.clientStubDecs <> requestStubDecs

clientRequestStub :: RpcApi -> Request -> Q [Q Dec]
clientRequestStub api req = do
  clientStubPrimeName <- newName req.name
  clientVarName <- newName "client"
  argNames <- sequence (newName . (.name) <$> req.fields)
  clientRequestStub' clientStubPrimeName clientVarName argNames
  where
    stubName :: Name
    stubName = clientRequestStubName api req
    makeStubSig :: Q [Type] -> Q Type
    makeStubSig arguments =
      [t|forall m. MonadIO m => $(buildFunctionType arguments [t|m $(buildTupleType (liftA2 (<>) optionalResultType (stubResourceTypes req)))|])|]
    optionalResultType :: Q [Type]
    optionalResultType = case req.mResponse of
                            Nothing -> pure []
                            Just resp -> sequence [[t|Awaitable $(buildTupleType (sequence ((.ty) <$> resp.fields)))|]]

    clientRequestStub' :: Name -> Name -> [Name] -> Q [Q Dec]
    clientRequestStub' clientStubPrimeName clientVarName argNames = do
      pure [
        clientRequestStubSigDec api req,
        funD stubName [clause ([varP clientVarName] <> varPats) body clientStubPrimeDecs]
        ]
      where
        clientE :: Q Exp
        clientE = varE clientVarName
        varPats :: [Q Pat]
        varPats = varP <$> argNames
        body :: Q Body
        body = case req.mResponse of
          Just resp -> normalB [|$(requestE resp requestDataE) >>= \(result, resources) -> $(varE clientStubPrimeName) result resources.createdChannels|]
          Nothing -> normalB [|$(sendE requestDataE) >>= \resources -> $(varE clientStubPrimeName) resources.createdChannels|]
        clientStubPrimeDecs :: [Q Dec]
        clientStubPrimeDecs = [
          sigD clientStubPrimeName (makeStubSig (liftA2 (<>) optionalResultType (sequence [[t|[Channel]|]]))),
          funD clientStubPrimeName (clientStubPrimeClauses req)
          ]
        clientStubPrimeClauses :: Request -> [Q Clause]
        clientStubPrimeClauses req = [mainClause, invalidChannelCountClause]
          where
            mainClause :: Q Clause
            mainClause = do
              resultAsyncName <- newName "result"

              channelNames <- sequence $ newName . ("channel" <>) . show <$> [0 .. (numPipelinedChannels req - 1)]

              clause
                (whenHasResult (varP resultAsyncName) <> [listP (varP <$> channelNames)])
                (normalB (buildTupleM (sequence (whenHasResult [|pure $(varE resultAsyncName)|] <> ((\x -> [|newStream $(varE x)|]) <$> channelNames)))))
                []

            invalidChannelCountClause :: Q Clause
            invalidChannelCountClause = do
              channelsName <- newName "newChannels"
              clause
                (whenHasResult wildP <> [varP channelsName])
                (normalB [|$(varE 'multiplexerInvalidChannelCount) $(litE (integerL (toInteger (numPipelinedChannels req)))) $(varE channelsName)|])
                []
        hasResponse :: Bool
        hasResponse = isJust req.mResponse
        whenHasResult :: a -> [a]
        whenHasResult x = [x | hasResponse]
        requestDataE :: Q Exp
        requestDataE = applyVars (conE (requestConName api req))
        messageConfigurationE :: Q Exp
        messageConfigurationE = [|defaultMessageConfiguration{createChannels = $(litE $ integerL $ toInteger $ numPipelinedChannels req)}|]
        sendE :: Q Exp -> Q Exp
        sendE msgExp = [|$typedSend $clientE $messageConfigurationE $msgExp|]
        requestE :: Response -> Q Exp -> Q Exp
        requestE resp msgExp = [|$typedRequest $clientE $checkResult $messageConfigurationE $msgExp|]
          where
            checkResult :: Q Exp
            checkResult = lamCaseE [valid, invalid]
            valid :: Q Match
            valid = do
              result <- newName "result"
              match (conP (responseConName api resp) [varP result]) (normalB [|pure $(varE result)|]) []
            invalid :: Q Match
            invalid = match wildP (normalB [|Nothing|]) []
        applyVars :: Q Exp -> Q Exp
        applyVars = go argNames
          where
            go :: [Name] -> Q Exp -> Q Exp
            go [] ex = ex
            go (n:ns) ex = go ns (appE ex (varE n))
        -- check if the response to a request matches the expected response constructor
        typedSend :: Q Exp
        typedSend = appTypeE (varE 'clientSend) (protocolType api)
        typedRequest :: Q Exp
        typedRequest = appTypeE (varE 'clientRequest) (protocolType api)

makeServer :: RpcApi -> Code -> Q [Dec]
makeServer api@RpcApi{functions} code = sequence [protocolImplDec, logicInstanceDec]
  where
    protocolImplDec :: Q Dec
    protocolImplDec = do
      dataD (pure []) (implRecordTypeName api) [] Nothing [recC (implRecordTypeName api) code.serverImplFields] []

    logicInstanceDec :: Q Dec
    logicInstanceDec = instanceD (cxt []) [t|HasProtocolImpl $(protocolType api)|] [
      tySynInstD (tySynEqn Nothing [t|ProtocolImpl $(protocolType api)|] (implRecordType api)),
      requestHandler
      ]
    requestHandler :: Q Dec
    requestHandler = do
      requestHandlerPrimeName <- newName "handleRequest"
      implRecordName <- newName "implementation"
      channelName <- newName "onChannel"
      funD 'handleRequest [clause [varP implRecordName, varP channelName] (normalB (varE requestHandlerPrimeName)) [funD requestHandlerPrimeName (requestHandlerClauses implRecordName channelName)]]
      where
        requestHandlerClauses :: Name -> Name -> [Q Clause]
        requestHandlerClauses implRecordName channelName = (mconcat $ (requestClauses implRecordName channelName) <$> code.requests)
        requestClauses :: Name -> Name -> Request -> [Q Clause]
        requestClauses implRecordName channelName req = [mainClause, invalidChannelCountClause]
          where
            mainClause :: Q Clause
            mainClause = do
              channelNames <- sequence $ newName . ("channel" <>) . show <$> [0 .. (numPipelinedChannels req - 1)]
              resourceNames <- sequence $ (\(res, num) -> newName (resourceNamePrefix res <> show num)) <$> zip req.createdResources [0 .. (numPipelinedChannels req - 1)]
              handlerName <- newName "handler"

              fieldNames <- sequence $ newName . (.name) <$> req.fields
              let requestConP = conP (requestConName api req) (varP <$> fieldNames)
                  ctx = RequestHandlerContext {
                    implRecordE = varE implRecordName,
                    argumentEs = varE <$> fieldNames,
                    resourceEs = varE <$> resourceNames
                  }
                  resourceEs = uncurry createResource <$> zip req.createdResources (varE <$> channelNames)

              clause
                [requestConP, listP (varP <$> channelNames)]
                (normalB (packResponse req.mResponse (applyResources resourceEs (varE handlerName))))
                [
                  handlerSig handlerName,
                  handlerDec handlerName resourceNames ctx
                ]

            handlerSig :: Name -> Q Dec
            handlerSig handlerName = sigD handlerName (buildFunctionType (implResourceTypes req) (implResultType req))
            handlerDec :: Name -> [Name] -> RequestHandlerContext -> Q Dec
            handlerDec handlerName resourceNames ctx = funD handlerName [clause (varP <$> resourceNames) (normalB (req.handlerE ctx)) []]
            applyResources :: [Q Exp] -> Q Exp -> Q Exp
            applyResources resourceEs implE = applyM implE resourceEs

            invalidChannelCountClause :: Q Clause
            invalidChannelCountClause = do
              channelsName <- newName "newChannels"
              let requestConP = conP (requestConName api req) (replicate (length req.fields) wildP)
              clause
                [requestConP, varP channelsName]
                (normalB [|$(varE 'reportInvalidChannelCount) $(litE (integerL (toInteger (numPipelinedChannels req)))) $(varE channelsName) $(varE channelName)|])
                []

    packResponse :: Maybe Response -> Q Exp -> Q Exp
    packResponse Nothing handlerE = [|Nothing <$ $(handlerE)|]
    packResponse (Just response) handlerE = [|Just . fmap $(conE (responseConName api response)) <$> $handlerE|]


-- * Pluggable codegen interface

data Code = Code {
  clientStubDecs :: [Q Dec],
  serverImplFields :: [Q VarBangType],
  requests :: [Request]
}
instance Semigroup Code where
  x <> y = Code {
    clientStubDecs = x.clientStubDecs <> y.clientStubDecs,
    serverImplFields = x.serverImplFields <> y.serverImplFields,
    requests = x.requests <> y.requests
  }
instance Monoid Code where
  mempty = Code {
    clientStubDecs = [],
    serverImplFields = [],
    requests = []
  }

data Request = Request {
  name :: String,
  fields :: [Field],
  createdResources :: [RequestCreateResource],
  mResponse :: Maybe Response,
  handlerE :: RequestHandlerContext -> Q Exp
}

data RequestCreateResource = RequestCreateChannel | RequestCreateStream (Q Type) (Q Type)

data Response = Response {
  name :: String,
  fields :: [Field]
  --numCreatedChannels :: Int
}

data Field = Field {
  name :: String,
  ty :: Q Type
}
toField :: (HasField "name" a String, HasField "ty" a (Q Type)) => a -> Field
toField x = Field { name = x.name, ty = x.ty }

data RequestHandlerContext = RequestHandlerContext {
  implRecordE :: Q Exp,
  argumentEs :: [Q Exp],
  resourceEs :: [Q Exp]
}


-- * Rpc function code generator

generateObservable :: RpcApi -> RpcObservable -> Q Code
generateObservable api observable = pure Code {
  clientStubDecs = observableStubDec,
  requests = [observeRequest, retrieveRequest],
  serverImplFields = [varDefaultBangType serverImplFieldName serverImplFieldSig]
}
  where
    observeRequest :: Request
    observeRequest = Request {
      name = observable.name <> "_observe",
      fields = [],
      createdResources = [RequestCreateStream [t|Void|] [t|PackedObservableMessage $(observable.ty)|]],
      mResponse = Nothing,
      handlerE = \ctx -> [|observeToStream $(observableE ctx) $(ctx.resourceEs !! 0)|]
      }
    retrieveRequest :: Request
    retrieveRequest = Request {
      name = observable.name <> "_retrieve",
      fields = [],
      createdResources = [],
      mResponse = Just retrieveResponse,
      handlerE = \ctx -> [|retrieve $(observableE ctx)|]
      }
    retrieveResponse :: Response
    retrieveResponse = Response {
      name = observable.name <> "_retrieve",
      fields = [Field "result" observable.ty]
    }
    serverImplFieldName :: Name
    serverImplFieldName = mkName (observable.name <> "Impl")
    serverImplFieldSig :: Q Type
    serverImplFieldSig = [t|Observable $(observable.ty)|]
    observableE :: RequestHandlerContext -> Q Exp
    observableE ctx = [|$(varE serverImplFieldName) $(ctx.implRecordE)|]
    observableStubDec :: [Q Dec]
    observableStubDec = [
      sigD (mkName observable.name) [t|$(clientType api) -> IO (Observable $(observable.ty))|],
      do
        clientName <- newName "client"
        let clientE = varE clientName
        funD (mkName observable.name) [
          clause [varP clientName] (normalB [|newObservableStub ($(clientRequestStubE api retrieveRequest) $clientE) ($(clientRequestStubE api observeRequest) $clientE)|]) []
          ]
      ]
    observeE :: Q Exp
    observeE = clientRequestStubE api observeRequest
    retrieveE :: Q Exp
    retrieveE = clientRequestStubE api retrieveRequest

generateFunction :: RpcApi -> RpcFunction -> Q Code
generateFunction api fun = do
  clientStubDecs <- clientFunctionStub
  pure Code {
    clientStubDecs,
    serverImplFields =
      if isNothing fun.fixedHandler
        then [varDefaultBangType implFieldName implSig]
        else [],
    requests = [request]
  }
  where
    request :: Request
    request = Request {
      name = fun.name,
      fields = toField <$> fun.arguments,
      createdResources = (\stream -> RequestCreateStream stream.tyUp stream.tyDown) <$> fun.streams,
      mResponse = if hasResult fun then Just response else Nothing,
      handlerE = serverRequestHandlerE
    }
    response :: Response
    response = Response {
      name = fun.name,
      -- TODO unpack?
      fields = [ Field { name = "packedResponse", ty = buildTupleType (sequence ((.ty) <$> fun.results)) } ]
    }
    implFieldName :: Name
    implFieldName = functionImplFieldName api fun
    implSig :: Q Type
    implSig = buildFunctionType ((functionArgumentTypes fun) <<>> (implResourceTypes request)) (implResultType request)

    serverRequestHandlerE :: RequestHandlerContext -> Q Exp
    serverRequestHandlerE ctx = applyResources (applyArgs (implFieldE ctx.implRecordE)) ctx.resourceEs
      where
        implFieldE :: Q Exp -> Q Exp
        implFieldE implRecordE = case fun.fixedHandler of
          Nothing -> [|$(varE implFieldName) $implRecordE|]
          Just handler -> [|$(handler) :: $implSig|]
        applyArgs :: Q Exp -> Q Exp
        applyArgs implE = foldl appE implE ctx.argumentEs
        applyResources :: Q Exp -> [Q Exp] -> Q Exp
        applyResources implE resourceEs = foldl appE implE resourceEs

    clientFunctionStub :: Q [Q Dec]
    clientFunctionStub = do
      funArgTypes <- functionArgumentTypes fun
      pure [
        sigD funName (clientRequestStubSig api request),
        funD funName [clause [] (normalB (clientRequestStubE api request)) []]
        ]
      where
        funName :: Name
        funName = mkName fun.name


functionArgumentTypes :: RpcFunction -> Q [Type]
functionArgumentTypes fun = sequence $ (.ty) <$> fun.arguments

functionResultTypes :: RpcFunction -> Q [Type]
functionResultTypes fun = sequence $ (.ty) <$> fun.results

hasResult :: RpcFunction -> Bool
hasResult fun = not (null fun.results)

numPipelinedChannels :: Request -> Int
numPipelinedChannels req = length req.createdResources

protocolTypeName :: RpcApi -> Name
protocolTypeName RpcApi{name} = mkName (name <> "Protocol")

protocolType :: RpcApi -> Q Type
protocolType = conT . protocolTypeName

requestTypeIdentifier :: RpcApi -> String
requestTypeIdentifier RpcApi{name} = name <> "ProtocolRequest"

requestTypeName :: RpcApi -> Name
requestTypeName = mkName . requestTypeIdentifier

requestConName :: RpcApi -> Request -> Name
requestConName api req = mkName (requestTypeIdentifier api <> "_" <> req.name)

responseTypeIdentifier :: RpcApi -> String
responseTypeIdentifier RpcApi{name} = name <> "ProtocolResponse"

responseTypeName :: RpcApi -> Name
responseTypeName = mkName . responseTypeIdentifier

responseFunctionCtorName :: RpcApi -> RpcFunction -> Name
responseFunctionCtorName api fun = mkName (responseTypeIdentifier api <> "_" <> fun.name)

responseConName :: RpcApi -> Response -> Name
responseConName api resp = mkName (responseTypeIdentifier api <> "_" <> resp.name)

clientType :: RpcApi -> Q Type
clientType api = [t|Client $(protocolType api)|]

implRecordTypeName :: RpcApi -> Name
implRecordTypeName RpcApi{name} = mkName $ name <> "ProtocolImpl"

implRecordType :: RpcApi -> Q Type
implRecordType = conT . implRecordTypeName

functionImplFieldName :: RpcApi -> RpcFunction -> Name
functionImplFieldName _api fun = mkName (fun.name <> "Impl")

clientRequestStubName :: RpcApi -> Request -> Name
clientRequestStubName api req = mkName ("_" <> api.name <> "_" <> req.name)

clientRequestStubE :: RpcApi -> Request -> Q Exp
clientRequestStubE api req = (varE (clientRequestStubName api req))

clientRequestStubSig :: RpcApi -> Request -> Q Type
clientRequestStubSig api req = makeStubSig (sequence ((clientType api) : ((.ty) <$> req.fields)))
  where
    makeStubSig :: Q [Type] -> Q Type
    makeStubSig arguments =
      [t|forall m. MonadIO m => $(buildFunctionType arguments [t|m $(buildTupleType (liftA2 (<>) optionalResultType (stubResourceTypes req)))|])|]
    optionalResultType :: Q [Type]
    optionalResultType = case req.mResponse of
                            Nothing -> pure []
                            Just resp -> sequence [[t|Awaitable $(buildTupleType (sequence ((.ty) <$> resp.fields)))|]]

clientRequestStubSigDec :: RpcApi -> Request -> Q Dec
clientRequestStubSigDec api req = sigD (clientRequestStubName api req) (clientRequestStubSig api req)

stubResourceTypes :: Request -> Q [Type]
stubResourceTypes req = sequence $ stubResourceType <$> req.createdResources

implResourceTypes :: Request -> Q [Type]
implResourceTypes req = sequence $ implResourceType <$> req.createdResources

stubResourceType :: RequestCreateResource -> Q Type
stubResourceType RequestCreateChannel = [t|Channel|]
stubResourceType (RequestCreateStream up down) = [t|Stream $up $down|]

implResourceType :: RequestCreateResource -> Q Type
implResourceType RequestCreateChannel = [t|Channel|]
implResourceType (RequestCreateStream up down) = [t|Stream $down $up|]

resourceNamePrefix :: RequestCreateResource -> String
resourceNamePrefix RequestCreateChannel = "channel"
resourceNamePrefix (RequestCreateStream _ _) = "stream"

createResource :: RequestCreateResource -> Q Exp -> Q Exp
createResource RequestCreateChannel channelE = [|pure $channelE|]
createResource (RequestCreateStream up down) channelE = [|newStream $channelE|]

implResultType :: Request -> Q Type
implResultType req = [t|forall m. HasResourceManager m => m $(resultType)|]
  where
    resultType = case req.mResponse of
      Nothing -> [t|()|]
      Just resp -> [t|Task $(buildTupleType (sequence ((.ty) <$> resp.fields)))|]

-- * Template Haskell helper functions

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

-- | [a, b, c] -> (a, b, c)
-- [a] -> a
-- [] -> ()
buildTuple :: Q [Exp] -> Q Exp
buildTuple fields = buildTuple' =<< fields
  where
    buildTuple' :: [Exp] -> Q Exp
    buildTuple' [] = [|()|]
    buildTuple' [single] = pure single
    buildTuple' fs = pure $ TupE (Just <$> fs)

-- | [m a, m b, m c] -> m (a, b, c)
-- [m a] -> m a
-- [] -> m ()
buildTupleM :: Q [Exp] -> Q Exp
buildTupleM fields = buildTuple' =<< fields
  where
    buildTuple' :: [Exp] -> Q Exp
    buildTuple' [] = [|pure ()|]
    buildTuple' [single] = pure single
    buildTuple' fs = pure (TupE (const Nothing <$> fs)) `applyA` (pure <$> fs)

-- | (a -> b -> c -> d) -> [m a, m b, m c] -> m d
applyA :: Q Exp -> [Q Exp] -> Q Exp
applyA con [] = [|pure $con|]
applyA con (monadicE:monadicEs) = foldl (\x y -> [|$x <*> $y|]) [|$con <$> $monadicE|] monadicEs

-- | (a -> b -> c -> m d) -> [m a, m b, m c] -> m d
applyM :: Q Exp -> [Q Exp] -> Q Exp
applyM con [] = con
applyM con args = [|join $(applyA con args)|]

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


-- * Error reporting

reportInvalidChannelCount :: MonadIO m => Int -> [Channel] -> Channel -> m a
reportInvalidChannelCount expectedCount newChannels onChannel = channelReportProtocolError onChannel msg
  where
    msg = mconcat parts
    parts = ["Received ", show (length newChannels), " new channels, but expected ", show expectedCount]

multiplexerInvalidChannelCount :: MonadIO m => Int -> [Channel] -> m a
multiplexerInvalidChannelCount expectedCount newChannels = liftIO $ fail msg
  where
    msg = mconcat parts
    parts = ["Internal error: Multiplexer created ", show (length newChannels), " new channels, but expected ", show expectedCount]
