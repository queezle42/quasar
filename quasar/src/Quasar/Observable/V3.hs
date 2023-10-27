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
type data ChangeKind = Unchanged | NoUnchanged
type data DeltaKind = NoDelta | YesDelta

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

data ChangeKind = Unchanged | NoUnchanged
type Unchanged = 'Unchanged
type NoUnchanged = 'NoUnchanged

data DeltaKind = NoDelta | YesDelta
type NoDelta = 'NoDelta
type YesDelta = 'YesDelta

#endif

type LoadingAndPending :: LoadKind -> PendingKind -> Type
data LoadingAndPending canLoad pending where
  LiveP :: LoadingAndPending canLoad pending
  LoadingPending :: LoadingAndPending Load Pending


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

type ObservableChange :: ContextKind -> PendingKind -> ChangeKind -> DeltaKind -> LoadKind -> (Type -> Type) -> Type -> Type
data ObservableChange ctx pending change canDelta canLoad c v where
  ObservableUnchanged :: Loading canLoad -> ObservableInfo ctx c v -> ObservableChange ctx pending Unchanged canDelta Load c v
  ObservableCleared :: ObservableChange ctx pending change canDelta Load c v
  ObservablePendingReplace :: c v -> ObservableChange ctx Pending change canDelta Load c v
  ObservablePendingDelta :: ObservableDelta ctx c v -> ObservableChange ctx Pending change YesDelta Load c v
  ObservableLiveReplace :: c v -> ObservableChange ctx pending change canDelta canLoad c v
  ObservableLiveDelta :: ObservableDelta ctx c v -> ObservableChange ctx pending change YesDelta canLoad c v

  --ObservableReplace :: Loading (canLoad && pending) -> c v -> ObservableChange ctx Pending change canDelta Load c v
  --ObservableEx :: Loading (canLoad && pending) -> Ex exceptions -> ObservableChange ctx Pending change canDelta Load c v
  --ObservableDelta :: Loading (canLoad && pending) -> ObservableDelta ctx c v -> ObservableChange ctx pending change YesDelta canLoad c v


-- | A "normal" change that can be applied to an observer.
type PlainChange = ObservableChange NoContext NotPending Unchanged YesDelta
type EvaluatedChange = ObservableChange Evaluated NotPending Unchanged YesDelta
type ValidatedChange = ObservableChange Validated NotPending Unchanged YesDelta
type PendingChange = ObservableChange NoContext Pending Unchanged YesDelta
type PlainUpdate = ObservableChange NoContext NotPending NoUnchanged YesDelta NoLoad
type ValidatedUpdate = ObservableChange Validated NotPending NoUnchanged YesDelta NoLoad
type ObservableState = ObservableChange NoContext NotPending NoUnchanged NoDelta
type ObserverState = ObservableChange NoContext Pending NoUnchanged NoDelta
