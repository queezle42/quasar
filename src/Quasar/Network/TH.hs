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

import Control.Monad.State (State, execState)
import qualified Control.Monad.State as State
import Data.Binary (Binary)
import Data.Maybe (isNothing)
import GHC.Records.Compat (HasField)
import Language.Haskell.TH hiding (interruptible)
import Language.Haskell.TH.Syntax
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Prelude

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
makeRpc api = do
  code <- mconcat <$> sequence (generateFunction api <$> api.functions)
  mconcat <$> sequence [makeProtocol api code, makeClient code, makeServer api code]

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
      derivClause Nothing [[t|Eq|], [t|Show|], [t|Generic|], [t|Binary|]]
      ]

makeClient :: Code -> Q [Dec]
makeClient code = sequence code.clientStubDecs

makeServer :: RpcApi -> Code -> Q [Dec]
makeServer api@RpcApi{functions} code = sequence [protocolImplDec, logicInstanceDec]
  where
    protocolImplDec :: Q Dec
    protocolImplDec = do
      dataD (pure []) (implTypeName api) [] Nothing [recC (implTypeName api) code.serverImplFields] []
    functionImplType :: RpcFunction -> Q Type
    functionImplType fun = do
      argumentTypes <- functionArgumentTypes fun
      streamTypes <- serverStreamTypes
      buildFunctionType (pure (argumentTypes <> streamTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]
      where
        serverStreamTypes :: Q [Type]
        serverStreamTypes = sequence $ (\stream -> [t|Stream $(stream.tyDown) $(stream.tyUp)|]) <$> fun.streams

    logicInstanceDec :: Q Dec
    logicInstanceDec = instanceD (cxt []) [t|HasProtocolImpl $(protocolType api)|] [
      tySynInstD (tySynEqn Nothing [t|ProtocolImpl $(protocolType api)|] (implType api)),
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
              channelNames <- sequence $ newName . ("channel" <>) . show <$> [0 .. (req.numPipelinedChannels - 1)]

              fieldNames <- sequence $ newName . (.name) <$> req.fields
              let requestConP = conP (requestConName api req) (varP <$> fieldNames)
                  ctx = RequestHandlerContext {
                    implRecordE = varE implRecordName,
                    argumentEs = (varE <$> fieldNames),
                    channelEs = (varE <$> channelNames)
                  }

              clause
                [requestConP, listP (varP <$> channelNames)]
                (normalB (packResponse req.mResponse (req.handlerE ctx)))
                []

            invalidChannelCountClause :: Q Clause
            invalidChannelCountClause = do
              channelsName <- newName "newChannels"
              let requestConP = conP (requestConName api req) (replicate (length req.fields) wildP)
              clause
                [requestConP, varP channelsName]
                (normalB [|$(varE 'reportInvalidChannelCount) $(litE (integerL (toInteger req.numPipelinedChannels))) $(varE channelsName) $(varE channelName)|])
                []

    packResponse :: Maybe Response -> Q Exp -> Q Exp
    packResponse Nothing handlerE = [|Nothing <$ $(handlerE)|]
    packResponse (Just response) handlerE = [|Just . $(conE (responseConName api response)) <$> $handlerE|]


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
  numPipelinedChannels :: Int,
  mResponse :: Maybe Response,
  handlerE :: RequestHandlerContext -> Q Exp
}

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
  channelEs :: [Q Exp]
}


-- * Rpc function code generator

generateFunction :: RpcApi -> RpcFunction -> Q Code
generateFunction api fun = do
  clientStubDecs <- clientFunctionStub
  pure Code {
    clientStubDecs,
    serverImplFields =
      if isNothing fun.fixedHandler
        then [ varDefaultBangType implFieldName implSig ]
        else [],
    requests = [request]
  }
  where
    request :: Request
    request = Request {
      name = fun.name,
      fields = toField <$> fun.arguments,
      numPipelinedChannels = length fun.streams,
      mResponse = if hasResult fun then Just response else Nothing,
      handlerE = serverRequestHandlerE
    }
    response :: Response
    response = Response {
      name = fun.name,
      -- TODO unpack?
      fields = [ Field { name = "packedResponse", ty = buildTupleType (sequence ((.ty) <$> fun.results)) } ]
      --numCreatedChannels = undefined
    }
    implFieldName :: Name
    implFieldName = functionImplFieldName api fun
    implSig :: Q Type
    implSig = do
      argumentTypes <- functionArgumentTypes fun
      streamTypes <- serverStreamTypes
      buildFunctionType (pure (argumentTypes <> streamTypes)) [t|IO $(buildTupleType (functionResultTypes fun))|]
      where
        serverStreamTypes :: Q [Type]
        serverStreamTypes = sequence $ (\stream -> [t|Stream $(stream.tyDown) $(stream.tyUp)|]) <$> fun.streams

    serverRequestHandlerE :: RequestHandlerContext -> Q Exp
    serverRequestHandlerE ctx = applyChannels ctx.channelEs (applyArgs (implFieldE ctx.implRecordE))
      where
        implFieldE :: Q Exp -> Q Exp
        implFieldE implRecordE = case fun.fixedHandler of
          Nothing -> [|$(varE implFieldName) $implRecordE|]
          Just handler -> [|$(handler) :: $implSig|]
        applyArgs :: Q Exp -> Q Exp
        applyArgs implE = foldl appE implE ctx.argumentEs
        applyChannels :: [Q Exp] -> Q Exp -> Q Exp
        applyChannels [] implE = implE
        applyChannels (channel0E:channelEs) implE = varE 'join `appE` foldl
          (\x y -> [|$x <*> $y|])
          ([|$implE <$> $(createStream channel0E)|])
          (createStream <$> channelEs)
          where
            createStream :: Q Exp -> Q Exp
            createStream = (varE 'newStream `appE`)

    clientFunctionStub :: Q [Q Dec]
    clientFunctionStub = do
      clientVarName <- newName "client"
      argNames <- sequence (newName . (.name) <$> fun.arguments)
      channelNames <- sequence (newName . (<> "Channel") . (.name) <$> fun.streams)
      streamNames <- sequence (newName . (.name) <$> fun.streams)
      makeClientFunction' clientVarName argNames channelNames streamNames
      where
        funName :: Name
        funName = mkName fun.name
        makeClientFunction' :: Name -> [Name] -> [Name] -> [Name] -> Q [Q Dec]
        makeClientFunction' clientVarName argNames channelNames streamNames = do
          funArgTypes <- functionArgumentTypes fun
          clientType <- [t|Client $(protocolType api)|]
          resultType <- optionalResultType
          streamTypes <- clientStreamTypes
          pure [
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
              | hasResult fun = do
                responseName <- newName "response"
                normalB $ doE $
                  [
                    bindS [p|($(varP responseName), resources)|] (requestE requestDataE),
                    bindS [p|result|] (checkResult (varE responseName))
                  ] <>
                  createStreams [|resources.createdChannels|] <>
                  [noBindS [|pure $(buildTuple (liftA2 (:) [|result|] streamsE))|]]
              | otherwise = normalB $ doE $
                  [bindS [p|resources|] (sendE requestDataE)] <>
                  createStreams [|resources.createdChannels|] <>
                  [noBindS [|pure $(buildTuple streamsE)|]]
            requestDataE :: Q Exp
            requestDataE = applyVars (conE (requestFunctionConName api fun))
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
                      match wildP (normalB [|fail "Invalid number of channel created"|]) []
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

functionArgumentTypes :: RpcFunction -> Q [Type]
functionArgumentTypes fun = sequence $ (.ty) <$> fun.arguments
functionResultTypes :: RpcFunction -> Q [Type]
functionResultTypes fun = sequence $ (.ty) <$> fun.results

hasResult :: RpcFunction -> Bool
hasResult fun = not (null fun.results)


-- ** Name helper functions

protocolTypeName :: RpcApi -> Name
protocolTypeName RpcApi{name} = mkName (name <> "Protocol")

protocolType :: RpcApi -> Q Type
protocolType = conT . protocolTypeName

requestTypeIdentifier :: RpcApi -> String
requestTypeIdentifier RpcApi{name} = name <> "ProtocolRequest"

requestTypeName :: RpcApi -> Name
requestTypeName = mkName . requestTypeIdentifier

requestFunctionConName :: RpcApi -> RpcFunction -> Name
requestFunctionConName api fun = mkName (requestTypeIdentifier api <> "_" <> fun.name)

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

implTypeName :: RpcApi -> Name
implTypeName RpcApi{name} = mkName $ name <> "ProtocolImpl"

implType :: RpcApi -> Q Type
implType = conT . implTypeName

functionImplFieldName :: RpcApi -> RpcFunction -> Name
functionImplFieldName _api fun = mkName (fun.name <> "Impl")

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

-- * Error reporting

reportInvalidChannelCount :: Int -> [Channel] -> Channel -> IO a
reportInvalidChannelCount expectedCount newChannels onChannel = channelReportProtocolError onChannel msg
  where
    msg = mconcat parts
    parts = ["Received ", show (length newChannels), " new channels, but expected ", show expectedCount]
