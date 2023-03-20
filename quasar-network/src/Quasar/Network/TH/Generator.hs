module Quasar.Network.TH.Generator (
  makeInterface,
) where

import Control.Monad.Writer
import Data.Foldable (toList)
import Data.List (singleton, intersperse)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Records (HasField(getField))
import Language.Haskell.TH
import Quasar
import Quasar.Prelude hiding (Type)
import Quasar.Network.Runtime
import Quasar.Network.TH.Spec

-- * Names

className :: InterfaceSpec -> Name
className spec = mkName ("Is" <> spec.name)

quantifyFnName :: InterfaceSpec -> Name
quantifyFnName spec = mkName ("to" <> spec.name)

quantificationTypeName :: InterfaceSpec -> Name
quantificationTypeName spec = mkName spec.name

quantificationConName :: InterfaceSpec -> Name
quantificationConName spec = mkName ("Some" <> spec.name)

recordName :: InterfaceSpec -> Name
recordName spec = mkName (spec.name <> "'")

recordConName :: InterfaceSpec -> Name
recordConName = recordName

proxyName :: InterfaceSpec -> Name
proxyName spec = mkName (spec.name <> "Proxy")

proxyConName :: InterfaceSpec -> Name
proxyConName = proxyName

-- * Generator

-- ** Entry point

makeInterface :: InterfaceSpec -> Q [Dec]
makeInterface spec = do
  checkExtensions
  interfaceClass <- makeInterfaceClass spec
  quantification <- makeInterfaceQuantificationType spec
  record <- makeInterfaceRecord spec
  network <- makeNetworkCode spec
  pure $ mconcat [interfaceClass, quantification, record, network]

-- ** Extensions

requiredExtensions :: Set Extension
requiredExtensions = Set.fromList [
  DuplicateRecordFields,
  ExistentialQuantification
  ]

checkExtensions :: Q ()
checkExtensions = do
  exts <- extsEnabled
  let missingExtensions = requiredExtensions `Set.difference` Set.fromList exts
  when (not (Set.null missingExtensions)) do
    fail $ "Missing required extensions: " <> mconcat (intersperse "," (show <$> toList missingExtensions))

-- ** Types

-- Existential quantification type for an interface
quantificationType :: InterfaceSpec -> Q Type
quantificationType spec = conT (quantificationTypeName spec)

-- Type has kind (Type -> Constraint)
interfaceConstraint :: InterfaceSpec -> Q Type
interfaceConstraint spec = conT (className spec)

-- Type has kind (Constraint).
interfaceMemberConstraint :: Q Type -> MemberSpec -> Q Type
interfaceMemberConstraint aT spec = hasFieldT spec.name aT (interfaceMemberType spec)

interfaceMemberType :: MemberSpec -> Q Type
interfaceMemberType (FunctionMemberSpec function) = interfaceFunctionType function
interfaceMemberType (FieldMemberSpec field) = specType field.ty

interfaceFunctionType :: FunctionSpec -> Q Type
interfaceFunctionType spec = foldr funT returnT (argumentT <$> spec.arguments :: [Q Type])
  where
    returnT :: Q Type
    returnT = [t|QuasarIO $resultsT|]
    resultsT :: Q Type
    resultsT = buildTupleT (specType . (.ty) <$> spec.results)
    argumentT :: ArgumentSpec -> Q Type
    argumentT = specType . (.ty)

proxyType :: InterfaceSpec -> Q Type
proxyType spec = conT (proxyName spec)

-- ** Declarations

makeInterfaceClass :: InterfaceSpec -> Q [Dec]
makeInterfaceClass spec = singleton <$>
  classD (cxt constraints) name [plainTV aName] [] [quantifyFnSigD, defaultQuantifyFnD]
  where
    name = className spec
    aName = mkName "a"
    aT :: Q Type
    aT = pure $ VarT aName
    constraints :: [Q Type]
    constraints = interfaceMemberConstraint aT <$> toList spec.members
    quantifyFnSigD :: Q Dec
    quantifyFnSigD = sigD (quantifyFnName spec) [t|$aT -> $(quantificationType spec)|]
    defaultQuantifyFnD :: Q Dec
    defaultQuantifyFnD = valD (varP (quantifyFnName spec)) (normalB (conE (quantificationConName spec))) []

makeInterfaceQuantificationType :: InterfaceSpec -> Q [Dec]
makeInterfaceQuantificationType spec = quantificationTypeD <<>> (quantificationInstanceD spec)
  where
    quantificationTypeD :: Q [Dec]
    quantificationTypeD = singleton <$>
      dataD (cxt []) name [] Nothing [forallC [PlainTV aName specifiedSpec] (cxt [appliedInterfaceConstraint]) (normalC conName [defaultBangType aT])] []
      where
        name = quantificationTypeName spec
        conName = quantificationConName spec
        aName = mkName "a"
        aT :: Q Type
        aT = pure $ VarT aName
        appliedInterfaceConstraint :: Q Type
        appliedInterfaceConstraint = [t|$(interfaceConstraint spec) $aT|]

quantificationInstanceD :: InterfaceSpec -> Q [Dec]
quantificationInstanceD spec = interfaceInstanceD <<>> (concat <$> mapM memberInstanceD spec.members)
  where
    interfaceInstanceD :: Q [Dec]
    interfaceInstanceD = singleton <$>
      instanceD (cxt []) [t|$(interfaceConstraint spec) $(quantificationType spec)|] [quantifyFnD]
    quantifyFnD :: Q Dec
    quantifyFnD = valD (varP (quantifyFnName spec)) (normalB [|id|]) []
    memberInstanceD :: MemberSpec -> Q [Dec]
    memberInstanceD memberSpec = singleton <$>
      instanceD (cxt []) (interfaceMemberConstraint (quantificationType spec) memberSpec) [getFieldD memberSpec]
    getFieldD :: MemberSpec -> Q Dec
    getFieldD memberSpec = funD 'getField [gfClause]
      where
        gfClause :: Q Clause
        gfClause = clause [gfPat] gfBody []
        gfPat :: Q Pat
        gfPat = conP (quantificationConName spec) [varP xN]
        gfBody :: Q Body
        gfBody = normalB (hasFieldGetFieldE (varE xN) memberSpec.name)
        xN :: Name
        xN = mkName "x"

makeInterfaceRecord :: InterfaceSpec -> Q [Dec]
makeInterfaceRecord spec = recordD <<>> interfaceInstanceD
  where
    recordD = singleton <$> dataD (cxt []) name [] Nothing [con] []
    name = recordName spec
    con :: Q Con
    con = recC (recordConName spec) (member <$> toList spec.members)
    member :: MemberSpec -> Q VarBangType
    member memberSpec = varDefaultBangType (mkName memberSpec.name) (interfaceMemberType memberSpec)
    interfaceInstanceD :: Q [Dec]
    interfaceInstanceD = singleton <$>
      instanceD (cxt []) [t|$(interfaceConstraint spec) $(conT (recordName spec))|] []

-- *** Proxy and NetworkReference instance

makeNetworkCode :: InterfaceSpec -> Q [Dec]
makeNetworkCode spec = proxyD spec <<>> networkReferenceInstanceD spec <<>> networkObjectInstanceD spec

proxyD :: InterfaceSpec -> Q [Dec]
proxyD spec = proxyTypeD spec <<>> interfaceInstanceD
  where
    proxyTypeD spec = singleton <$> dataD (cxt []) name [] Nothing [con] []
    name = proxyName spec
    con :: Q Con
    con = recC (proxyConName spec) (catMaybes (member <$> toList spec.members))
    member :: MemberSpec -> Maybe (Q VarBangType)
    member (FieldMemberSpec field) = Just $ varDefaultBangType (mkName field.name) (specType field.ty)
    member (FunctionMemberSpec _) = Nothing
    interfaceInstanceD :: Q [Dec]
    interfaceInstanceD = singleton <$>
      instanceD (cxt []) [t|$(interfaceConstraint spec) $(proxyType spec)|] []

proxyChannelType :: InterfaceSpec -> Q Type
proxyChannelType spec = [t|Channel $up $down|]
  where
    -- Constructor data
    up :: Q Type
    up = [t|()|]
    -- Requests
    down :: Q Type
    down = [t|Void|]

-- `NetworkReference`-instance
networkReferenceInstanceD :: InterfaceSpec -> Q [Dec]
networkReferenceInstanceD spec = singleton <$>
  instanceD (cxt []) [t|NetworkReference $targetType|] [channelTypeD, sendReferenceD, receiveReferenceD]
  where
    targetType :: Q Type
    targetType = quantificationType spec
    channelTypeD :: Q Dec
    channelTypeD = tySynInstD (tySynEqn Nothing [t|NetworkReferenceChannel $targetType|] (proxyChannelType spec))
    sendReferenceD :: Q Dec
    sendReferenceD = funD 'sendReference [clause [] (normalB [|undefined|]) []]
    receiveReferenceD :: Q Dec
    receiveReferenceD = funD 'receiveReference [clause [] (normalB [|undefined|]) []]

-- `NetworkObject` instance, using the `NetworkReference` instance
networkObjectInstanceD :: InterfaceSpec -> Q [Dec]
networkObjectInstanceD spec = singleton <$> instanceD (cxt []) [t|NetworkObject $targetType|] [strategyD]
  where
    targetType :: Q Type
    targetType = quantificationType spec
    strategyD :: Q Dec
    strategyD = tySynInstD (tySynEqn Nothing [t|NetworkStrategy $targetType|] [t|NetworkReference|])

--instance NetworkReference Foobar where
--  type NetworkReferenceChannel Foobar = Channel FoobarCData FoobarRequest
--  sendReference = sendObservableReference
--  receiveReference = receiveObservableReference

-- * GHC.Records.HasField

hasFieldT :: String -> Q Type -> Q Type -> Q Type
hasFieldT fieldName aT rT = [t|HasField $(litT (strTyLit fieldName)) $aT $rT|]

hasFieldGetFieldE :: Q Exp -> String -> Q Exp
hasFieldGetFieldE self fieldName = [|$(appTypeE [|getField|] (litT (strTyLit fieldName))) $self|]


-- * Utils

funT :: Q Type -> Q Type -> Q Type
funT x = appT (appT arrowT x)
infixr 0 `funT`

buildTupleT :: [Q Type] -> Q Type
buildTupleT fields = buildTupleType' fields
  where
    buildTupleType' :: [Q Type] -> Q Type
    buildTupleType' [] = [t|()|]
    buildTupleType' [single] = single
    buildTupleType' fs = go (tupleT (length fs)) fs
    go :: Q Type -> [Q Type] -> Q Type
    go t [] = t
    go t (f:fs) = go (appT t f) fs


defaultBangType  :: Q Type -> Q BangType
defaultBangType = bangType (bang noSourceUnpackedness noSourceStrictness)

varDefaultBangType  :: Name -> Q Type -> Q VarBangType
varDefaultBangType name qType = varBangType name $ bangType (bang noSourceUnpackedness noSourceStrictness) qType
