module Quasar.Network.TH.Spec (
  -- * Type specification
  IsTypeSpec(..),
  TypeSpec(..),

  BinaryTypeSpec(..),
  binaryType,
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
  addBinaryValue,
  addObservable,
) where

import Control.Monad.State (State, execState)
import Control.Monad.State qualified as State
import Data.Binary (Binary)
import Data.Sequence (Seq(Empty), (|>))
import GHC.Records (HasField(..))
import Language.Haskell.TH
import Quasar.Observable (Observable)
import Quasar.Prelude hiding (Type)

data KindSpec = ValueType | ReferenceType

class IsTypeSpec a where
  specType :: a -> Q Type
  -- Network references have a channel and their lifetime is bound to a parent; if false this is a value type that can be copied.
  typeSpecKind :: a -> KindSpec


-- | Quantification wrapper for `IsTypeSpec`
data TypeSpec = forall a. IsTypeSpec a => TypeSpec a

instance IsTypeSpec TypeSpec where
  specType (TypeSpec ty) = specType ty
  typeSpecKind (TypeSpec ty) = typeSpecKind ty


data BinaryTypeSpec = BinaryTypeSpec (Q Type)

instance IsTypeSpec BinaryTypeSpec where
  specType (BinaryTypeSpec ty) = ty
  typeSpecKind _ = ValueType

-- | Type has to implement a `Binary`-constraint
binaryType :: Q Type -> TypeSpec
binaryType = TypeSpec . BinaryTypeSpec


data InterfaceTypeSpec = InterfaceTypeSpec String

instance IsTypeSpec InterfaceTypeSpec where
  -- Directly refering to the quantification type by name for now
  -- TODO generating the name should be deferred to the TH generator (to verify the interface exists and to ensure the correct name is used)
  specType (InterfaceTypeSpec name) = conT (mkName name)
  typeSpecKind _ = ReferenceType

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

instance HasField "name" MemberSpec String where
  getField (FunctionMemberSpec x) = x.name
  getField (FieldMemberSpec x) = x.name

data FunctionSpec = FunctionSpec {
  name :: String,
  arguments :: [ArgumentSpec],
  results :: [ResultSpec]
}

data ArgumentSpec = ArgumentSpec {
  name :: String,
  ty :: TypeSpec
}

data ResultSpec = ResultSpec {
  name :: String,
  ty :: TypeSpec
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

addArgument :: String -> TypeSpec -> State FunctionSpec ()
addArgument name t = State.modify (\fun -> fun{arguments = fun.arguments <> [ArgumentSpec name t]})

addResult :: String -> TypeSpec -> State FunctionSpec ()
addResult name t = State.modify (\fun -> fun{results = fun.results <> [ResultSpec name t]})

addField :: String -> TypeSpec -> State InterfaceSpec ()
addField name ty = State.modify (\api -> api{members = api.members |> FieldMemberSpec (FieldSpec name ty)})

--addValue :: forall a. Binary a => String -> State InterfaceSpec ()
--addValue name = addField name (valueType @a)

addBinaryValue :: Q Type -> String -> State InterfaceSpec ()
addBinaryValue ty name = addField name (binaryType ty)


data ObservableSpec = ObservableSpec TypeSpec

instance IsTypeSpec ObservableSpec where
  specType (ObservableSpec ty) = [t|Observable $(specType ty)|]
  typeSpecKind _ = ReferenceType

observableType :: TypeSpec -> TypeSpec
observableType = TypeSpec . ObservableSpec

addObservable :: String -> TypeSpec -> State InterfaceSpec ()
addObservable name ty = addField name (observableType ty)
