{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.V3 (
) where

import Control.Applicative
import Control.Monad.Catch (MonadThrow(..), MonadCatch(..), bracket, fromException)
import Control.Monad.Except
import Data.Binary (Binary)
import Data.String (IsString(..))
import Data.Type.Equality ((:~:)(Refl))
import GHC.Records (HasField(..))
import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Existing type shims/copies

type Loading :: LoadKind -> Type
data Loading canLoad where
  Live :: Loading canLoad
  Loading :: Loading Load


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type Delta c :: Type -> Type
  type DeltaContext c
  type ValidatedDelta c :: Type -> Type

-- | Downstream change, information about the last change that was sent to an
-- observer.
type LastChange :: LoadKind -> Type
data LastChange canLoad where
  LastChangeCleared :: LastChange Load
  LastChangeAvailable :: Loading canLoad -> LastChange Load

-- * V3

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)

type data LoadKind = Load | NoLoad
type data ContextKind = NoContext | Validated | Evaluated
type data PendingKind = Pending | NotPending
type data ChangeKind = Change | NoChange

#else

data LoadKind = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad

data ContextKind = NoContext | Validated | Evaluated
type NoContext = 'NoContext
type Validated = 'Validated
type Evaluated = 'Evaluated

data PendingKind = Pending | NotPending
type Pending = 'Pending
type NotPending = 'NotPending

data ChangeKind = Change | NoChange
type Change = 'Change
type NoChange = 'NoChange

#endif

type LoadingP :: PendingKind -> LoadKind -> Type
data LoadingP pending canLoad where
  LiveP :: LoadingP pending canLoad
  LoadingP :: LoadingP Pending Load

instance HasField "loading" (LoadingP pending canLoad) (Loading canLoad) where
  getField LiveP = Live
  getField LoadingP = Loading


type ObservableDelta :: ContextKind -> (Type -> Type) -> Type -> Type
data ObservableDelta ctx c v where
  NoContextDelta :: Delta c v -> ObservableDelta NoContext c v
  ValidatedDelta :: ValidatedDelta c v -> ObservableDelta Validated c v
  EvaluatedDelta :: Delta c v -> c v -> ObservableDelta Evaluated c v

type ObservableInfo :: ContextKind -> (Type -> Type) -> Type -> Type
data ObservableInfo ctx c v where
  NoContextInfo :: ObservableInfo NoContext c v
  ValidatedInfo :: DeltaContext c -> ObservableInfo Validated c v
  EvaluatedInfo :: c v -> ObservableInfo Evaluated c v

type ObservableData :: ChangeKind -> PendingKind -> ContextKind -> LoadKind -> (Type -> Type) -> Type -> Type
data ObservableData change pending ctx canLoad c v where
  ObservableCleared :: ObservableData change pending ctx Load c v
  ObservableUnchanged :: Loading canLoad -> ObservableInfo ctx c v -> ObservableData Change pending ctx Load c v
  ObservableReplace :: LoadingP pending canLoad -> c v -> ObservableData change pending ctx canLoad c v
  --ObservableEx :: LoadingP pending canLoad -> Ex exceptions -> ObservableData change pending ctx canLoad c v
  ObservableDelta :: LoadingP pending canLoad -> ObservableDelta ctx c v -> ObservableData Change pending ctx canLoad c v


-- | A "normal" change that can be applied to an observer.
type PlainChange = ObservableData Change NotPending NoContext
type ValidatedChange = ObservableData Change NotPending Validated
type EvaluatedChange = ObservableData Change NotPending Evaluated
type PendingChange = ObservableData Change Pending Validated
type EvaluatedPendingChange = ObservableData Change Pending Evaluated
type PlainUpdate = ObservableData Change NotPending NoContext NoLoad
type ValidatedUpdate = ObservableData Change NotPending Validated NoLoad
type ObservableState = ObservableData NoChange NotPending NoContext
type ObserverState = ObservableData NoChange Pending NoContext
