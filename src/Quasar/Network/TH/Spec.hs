module Quasar.Network.TH.Spec (
  -- * Type specification
  IsTypeSpec(..),
  TypeSpec(..),

  ValueTypeSpec(..),
  valueType,
  ObservableSpec(..),
  observableType,
  InterfaceTypeSpec(..),
  interfaceType,

  -- * Interface specification
  InterfaceSpec(..),
  MemberSpec(..),
  FunctionSpec(..),
  ArgumentSpec(..),
  ResultSpec(..),
  FieldSpec(..),

  -- ** Monad-based inferface dsl
  interface,
  addFunction,
  addArgument,
  addResult,
  addField,
  addValue,
  addObservable,
) where

import Control.Monad.State (State, execState)
import Control.Monad.State qualified as State
import Data.Binary (Binary)
import Data.Sequence (Seq(Empty), (|>))
import Language.Haskell.TH
import Quasar.Observable (Observable)
import Quasar.Prelude hiding (Type)


class IsTypeSpec a where
  specType :: a -> Q Type
  -- Network references have a channel and their lifetime is bound to a parent; if false this is a value type that can be copied.
  isNetworkReference :: a -> Bool


-- | Quantification wrapper for `IsTypeSpec`
data TypeSpec = forall a. IsTypeSpec a => TypeSpec a

instance IsTypeSpec TypeSpec where
  specType (TypeSpec ty) = specType ty
  isNetworkReference (TypeSpec ty) = isNetworkReference ty


data ValueTypeSpec a = Binary a => ValueTypeSpec

instance IsTypeSpec (ValueTypeSpec a) where
  specType ValueTypeSpec = [t|a|]
  isNetworkReference _ = False

valueType :: forall a. Binary a => TypeSpec
valueType = TypeSpec $ ValueTypeSpec @a


data InterfaceTypeSpec = InterfaceTypeSpec String

instance IsTypeSpec InterfaceTypeSpec where
  -- Directly refering to the quantification type by name for now
  -- TODO verify the interface exists (class has to be changed to select the type later)
  specType (InterfaceTypeSpec name) = conT (mkName name)
  isNetworkReference _ = True

-- | A TypeSpec that refers to a generated interface type.
interfaceType :: String -> TypeSpec
interfaceType name = TypeSpec $ InterfaceTypeSpec name


data InterfaceSpec = InterfaceSpec {
  name :: String,
  members :: Seq MemberSpec
}

data MemberSpec
  = FunctionMemberSpec FunctionSpec
  | FieldMemberSpec FieldSpec

data FunctionSpec = FunctionSpec {
  name :: String,
  arguments :: [ArgumentSpec],
  results :: [ResultSpec]
}

data ArgumentSpec = ArgumentSpec {
  name :: String,
  ty :: Q Type
}

data ResultSpec = ResultSpec {
  name :: String,
  ty :: Q Type
}

data FieldSpec = FieldSpec {
  name :: String,
  ty :: TypeSpec
}

interface :: String -> State InterfaceSpec () -> InterfaceSpec
interface interfaceName setup = execState setup InterfaceSpec {
  name = interfaceName,
  members = Empty
}

addFunction :: String -> State FunctionSpec () -> State InterfaceSpec ()
addFunction methodName setup = State.modify (\api -> api{members = api.members |> FunctionMemberSpec fun})
  where
    fun = execState setup FunctionSpec {
      name = methodName,
      arguments = [],
      results = []
    }

addArgument :: String -> Q Type -> State FunctionSpec ()
addArgument name t = State.modify (\fun -> fun{arguments = fun.arguments <> [ArgumentSpec name t]})

addResult :: String -> Q Type -> State FunctionSpec ()
addResult name t = State.modify (\fun -> fun{results = fun.results <> [ResultSpec name t]})

addField :: String -> TypeSpec -> State InterfaceSpec ()
addField name ty = State.modify (\api -> api{members = api.members |> FieldMemberSpec (FieldSpec name ty)})

addValue :: forall a. Binary a => String -> State InterfaceSpec ()
addValue name = addField name (valueType @a)


data ObservableSpec = ObservableSpec TypeSpec

instance IsTypeSpec ObservableSpec where
  specType (ObservableSpec ty) = [t|Observable $(specType ty)|]
  isNetworkReference _ = True

observableType :: TypeSpec -> TypeSpec
observableType = TypeSpec . ObservableSpec

addObservable :: String -> TypeSpec -> State InterfaceSpec ()
addObservable name ty = addField name (observableType ty)
