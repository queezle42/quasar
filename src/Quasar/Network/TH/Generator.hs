module Quasar.Network.TH.Generator (
  makeInterface,
) where

import Control.Monad.Writer
import Language.Haskell.TH
import Quasar
import Quasar.Prelude hiding (Type)
import Quasar.Network.TH.Spec

-- classD :: Quote m => m Cxt -> Name -> [TyVarBndr ()] -> [FunDep] -> [m Dec] -> m Dec

makeInterface :: forall m. Quote m => InterfaceSpec -> m Dec
makeInterface spec =
  classD (cxt []) name [plainTV aName] [] decs
  where
    name = mkName spec.name
    aName = mkName "a"
    aT = VarT aName
    decs :: [m Dec]
    decs = concat $ interfaceMemberDecs <$> spec.members

-- sigD :: Quote m => Name -> m Type -> m Dec
-- defaultSigD :: Quote m => Name -> m Type -> m Dec
-- funD :: Quote m => Name -> [m Clause] -> m Dec

interfaceMemberDecs :: Quote m => MemberSpec -> [m Dec]
interfaceMemberDecs spec = [
  undefined -- sigD name (interfaceFunctionType spec)
  ]

interfaceFunctionDecs :: Quote m => FunctionSpec -> [m Dec]
interfaceFunctionDecs spec = [
  undefined -- sigD name (interfaceFunctionType spec)
  ]
  where
    name = mkName spec.name

interfaceFieldDecs :: Quote m => FieldSpec -> [m Dec]
interfaceFieldDecs spec = [
  ]
  where
    name = mkName spec.name


--data FunctionSpec = FunctionSpec {
--  name :: String,
--  arguments :: [ArgumentSpec],
--  results :: [ResultSpec]
--}
--
--data ArgumentSpec = ArgumentSpec {
--  name :: String,
--  ty :: Q Type
--}
--
--data ResultSpec = ResultSpec {
--  name :: String,
--  ty :: Q Type
--}

interfaceFunctionType :: Q Type -> FunctionSpec -> Q Type
interfaceFunctionType interfaceT spec = [t|$interfaceT -> $(foldl funT returnT (argumentT <$> spec.arguments :: [Q Type]))|]
  where
    returnT :: Q Type
    returnT = [t|QuasarIO (Future $resultsT)|]
    resultsT :: Q Type
    resultsT = buildTupleT ((.ty) <$> spec.results)
    argumentT :: ArgumentSpec -> Q Type
    argumentT = (.ty)


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
