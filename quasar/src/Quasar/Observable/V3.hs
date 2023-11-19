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


testPlainChangeCtors :: PlainChange Load Identity v -> ()
testPlainChangeCtors ObservableCleared = ()
testPlainChangeCtors (ObservableUnchanged Loading NoContextInfo) = ()
testPlainChangeCtors (ObservableUnchanged Live NoContextInfo) = ()
testPlainChangeCtors (ObservableReplace LiveP _new) = ()
testPlainChangeCtors (ObservableDelta LiveP _delta) = ()

testValidatedChangeCtors :: ValidatedChange Load Identity v -> ()
testValidatedChangeCtors ObservableCleared = ()
testValidatedChangeCtors (ObservableUnchanged Loading (ValidatedInfo _)) = ()
testValidatedChangeCtors (ObservableUnchanged Live (ValidatedInfo _)) = ()
testValidatedChangeCtors (ObservableReplace LiveP _new) = ()
testValidatedChangeCtors (ObservableDelta LiveP _delta) = ()

testPendingChangeCtors :: PendingChange Load Identity v -> ()
testPendingChangeCtors ObservableCleared = ()
testPendingChangeCtors (ObservableUnchanged Loading (ValidatedInfo _)) = ()
testPendingChangeCtors (ObservableUnchanged Live (ValidatedInfo _)) = ()
testPendingChangeCtors (ObservableReplace LoadingP _new) = ()
testPendingChangeCtors (ObservableDelta LoadingP _delta) = ()
testPendingChangeCtors (ObservableReplace LiveP _new) = ()
testPendingChangeCtors (ObservableDelta LiveP _delta) = ()

testEvaluatedPendingChangeCtors :: EvaluatedPendingChange Load Identity v -> ()
testEvaluatedPendingChangeCtors ObservableCleared = ()
testEvaluatedPendingChangeCtors (ObservableUnchanged Loading (EvaluatedInfo _)) = ()
testEvaluatedPendingChangeCtors (ObservableUnchanged Live (EvaluatedInfo _)) = ()
testEvaluatedPendingChangeCtors (ObservableReplace LoadingP _new) = ()
testEvaluatedPendingChangeCtors (ObservableDelta LoadingP _delta) = ()
testEvaluatedPendingChangeCtors (ObservableReplace LiveP _new) = ()
testEvaluatedPendingChangeCtors (ObservableDelta LiveP _delta) = ()

testValidatedUpdate :: ValidatedUpdate Identity v -> ()
testValidatedUpdate (ObservableDelta LiveP _delta) = ()
testValidatedUpdate (ObservableReplace LiveP _new) = ()

testPlainUpdateCtors :: PlainUpdate Identity v -> ()
testPlainUpdateCtors (ObservableReplace LiveP _new) = ()
testPlainUpdateCtors (ObservableDelta LiveP _delta) = ()

testObserverStateCtors :: ObserverState Load Identity v -> ()
testObserverStateCtors ObservableCleared = ()
testObserverStateCtors (ObservableReplace LoadingP _new) = ()
testObserverStateCtors (ObservableReplace LiveP _new) = ()

testObservableStateCtors :: ObservableState Load Identity v -> ()
testObservableStateCtors ObservableCleared = ()
testObservableStateCtors (ObservableReplace LiveP _new) = ()
