{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
  IsObservableCore(..),
  ObservableContainer(..),
  toInitialEvaluatedDelta,
  ContainerCount(..),

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanLoad(..),
#else
  CanLoad,
  Load,
  NoLoad,
#endif

  absurdLoad,

  ObservableT(..),
  ToObservableT(..),

  evaluateObservable,
  mapObservableContent,

  -- ** Additional types
  Loading(..),
  ObservableChange(.., ObservableChangeLiveDeltaOk, ObservableChangeLiveDeltaThrow, ObservableChangeLoading, ObservableChangeLive),
  mapObservableChangeDelta,
  EvaluatedObservableChange(.., EvaluatedObservableChangeLiveDeltaOk, EvaluatedObservableChangeLiveDeltaThrow),
  ObservableState(.., ObservableStateLiveOk, ObservableStateLiveEx),
  mapObservableState,
  mergeObservableState,
  ObserverState(.., ObserverStateLoading, ObserverStateLiveOk, ObserverStateLiveEx),
  createObserverState,
  toObservableState,
  applyObservableChange,
  applyEvaluatedObservableChange,
  toInitialChange,
  ObservableFunctor,

  MappedObservable(..),
  BindObservable(..),
  bindObservableT,

  -- *** Query
  Selector(..),
  Bounds,
  Bound(..),

  -- *** Exception wrapper container
  ObservableResult(..),
  ObservableResultDelta(..),
  unwrapObservableResult,
  mapObservableResult,
  mapObservableResultDelta,
  mergeObservableResult,

  -- *** Pending change helpers
  PendingChange,
  LastChange(..),
  updatePendingChange,
  initialPendingChange,
  initialPendingAndLastChange,
  changeFromPending,

  -- *** Merging changes
  MergeChange(..),
  MaybeL(..),
  attachMergeObserver,
  attachMonoidMergeObserver,
  attachEvaluatedMergeObserver,

  -- * Identity observable (single value without partial updates)
  Observable(..),
  ToObservable,
  toObservable,
  constObservable,
) where

import Control.Applicative
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Catch.Pure (MonadThrow(..))
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Data.String (IsString(..))
import Data.Type.Equality ((:~:)(Refl))
import GHC.Records (HasField(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type IsObservableCore :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class IsObservableCore canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable#
    :: canLoad ~ NoLoad
    => a
    -> STMc NoRetry exceptions (c v)

  attachObserver#
    :: ObservableContainer c v
    => a
    -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachObserver# x callback = attachEvaluatedObserver# x \evaluatedChange ->
    callback case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveDelta evaluated -> ObservableChangeLiveDelta (toDelta @(ObservableResult exceptions c) evaluated)

  attachEvaluatedObserver#
    :: ObservableContainer c v
    => a
    -> (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachEvaluatedObserver# x callback =
    mfixTVar \var -> do
      (disposer, initial) <- attachObserver# x \change -> do
        cached <- readTVar var
        forM_ (applyObservableChange change cached) \(evaluatedChange, newCached) -> do
          writeTVar var newCached
          callback evaluatedChange

      pure ((disposer, initial), createObserverState initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: ObservableFunctor c => (v -> vb) -> a -> MappedObservable canLoad exceptions c vb
  mapObservable# f x = MappedObservable f x

  count# :: (ContainerCount c, ObservableContainer c v) => a -> Observable canLoad exceptions Int64
  count# x = mapObservableContent containerCount# x

  isEmpty# :: (ContainerCount c, ObservableContainer c v) => a -> Observable canLoad exceptions Bool
  isEmpty# x = mapObservableContent containerIsEmpty# x

type Bounds k = (Bound k, Bound k)

data Bound k
  = ExcludingBound k
  | IncludingBound k
  | NoBound

data Selector k
  = Min
  | Max
  | Key k

evaluateObservable :: (IsObservableCore canLoad exceptions c v a, ObservableContainer c v) => a -> Observable canLoad exceptions (c v)
evaluateObservable x = toObservable (EvaluatedObservableCore x)

mapObservableContent
  :: (IsObservableCore canLoad exceptions c v a, ObservableContainer c v)
  => (c v -> va)
  -> a
  -> Observable canLoad exceptions va
mapObservableContent f x = Observable (ObservableT (mapObservable# f (evaluateObservable x)))

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanLoad = Load | NoLoad
#else
data CanLoad = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad
#endif

absurdLoad :: Load ~ NoLoad => a
absurdLoad = unreachableCodePath


data ObservableT canLoad exceptions c v
  = forall a. (IsObservableCore canLoad exceptions c v a, ContainerConstraint canLoad exceptions c v a) => ObservableT a

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (ObservableT canLoad exceptions c v) where
  readObservable# (ObservableT x) = readObservable# x
  attachObserver# (ObservableT x) = attachObserver# x
  attachEvaluatedObserver# (ObservableT x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableT x) = isCachedObservable# x
  mapObservable# f (ObservableT x) = mapObservable# f x
  count# (ObservableT x) = count# x
  isEmpty# (ObservableT x) = isEmpty# x

type ToObservableT :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ToObservableT canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  toObservableCore :: a -> ObservableT canLoad exceptions c v

instance ToObservableT canLoad exceptions c v (ObservableT canLoad exceptions c v) where
  toObservableCore = id


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type ContainerConstraint (canLoad :: CanLoad) (exceptions :: [Type]) c v a :: Constraint
  type Delta c :: Type -> Type
  type EvaluatedDelta c v :: Type
  type Key c v
  -- | Enough context to merge deltas.
  type DeltaContext c v
  type instance DeltaContext _c _v = ()

  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: (DeltaContext c v, Delta c v) -> Delta c v -> (DeltaContext c v, Delta c v)

  updateDeltaContext :: DeltaContext c v -> Delta c v -> DeltaContext c v
  default updateDeltaContext :: DeltaContext c v ~ () => DeltaContext c v -> Delta c v -> DeltaContext c v
  updateDeltaContext _ _ = ()

  -- | Produce a delta from a content. The delta replaces any previous content
  -- when applied.
  toInitialDelta :: c v -> Delta c v

  toInitialDeltaContext :: c v -> DeltaContext c v
  default toInitialDeltaContext :: DeltaContext c v ~ () => c v -> DeltaContext c v
  toInitialDeltaContext _ = ()

  -- | (Re)initialize the container content from a special delta. Using this
  -- function only produces a valid result when the previous observer state is
  -- `ObserverStateLoadingCleared`; otherwise the resulting container content is
  -- undefined.
  initializeFromDelta :: Delta c v -> c v

  toDelta :: EvaluatedDelta c v -> Delta c v
  toEvaluatedDelta :: Delta c v -> c v -> EvaluatedDelta c v
  toEvaluatedContent :: EvaluatedDelta c v -> c v

toInitialEvaluatedDelta :: ObservableContainer c v => c v -> EvaluatedDelta c v
toInitialEvaluatedDelta x = toEvaluatedDelta (toInitialDelta x) x

reinitializeFromDelta
  :: forall c v. ObservableContainer c v
  => Delta c v
  -> (DeltaContext c v, Delta c v)
reinitializeFromDelta delta =
  let initial = initializeFromDelta @c delta
  in (toInitialDeltaContext initial, toInitialDelta initial)

instance ObservableContainer Identity v where
  type ContainerConstraint _canLoad _exceptions Identity v _a = ()
  type Delta Identity = Identity
  type EvaluatedDelta Identity v = Identity v
  type Key Identity v = ()
  applyDelta new _ = new
  mergeDelta _ new = ((), new)
  updateDeltaContext _ _ = ()
  toInitialDelta = id
  toInitialDeltaContext _ = ()
  initializeFromDelta = id
  toDelta = id
  toEvaluatedDelta x _ = x
  toEvaluatedContent = id

class ContainerCount c where
  containerCount# :: c v -> Int64
  containerIsEmpty# :: c v -> Bool

instance ContainerCount Identity where
  containerCount# _ = 1
  containerIsEmpty# _ = False


type ObservableFunctor c = (Functor c, Functor (Delta c), forall v. ObservableContainer c v)


type ObservableChange :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableChange canLoad c v where
  ObservableChangeLoadingUnchanged :: ObservableChange Load c v
  ObservableChangeLoadingClear :: ObservableChange Load c v
  ObservableChangeLiveUnchanged :: ObservableChange canLoad c v
  ObservableChangeLiveDelta :: Delta c v -> ObservableChange canLoad c v

instance (Functor (Delta c)) => Functor (ObservableChange canLoad c) where
  fmap _fn ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  fmap _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
  fmap _fn ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  fmap fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fn <$> delta)

instance (Foldable (Delta c)) => Foldable (ObservableChange canLoad c) where
  foldMap f (ObservableChangeLiveDelta delta) = foldMap f delta
  foldMap _ _ = mempty

instance (Traversable (Delta c)) => Traversable (ObservableChange canLoad c) where
  traverse _fn ObservableChangeLoadingUnchanged = pure ObservableChangeLoadingUnchanged
  traverse _fn ObservableChangeLoadingClear = pure ObservableChangeLoadingClear
  traverse _fn ObservableChangeLiveUnchanged = pure ObservableChangeLiveUnchanged
  traverse f (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta <$> traverse f delta

{-# COMPLETE ObservableChangeLoading, ObservableChangeLive #-}
{-# COMPLETE ObservableChangeLoading, ObservableChangeLiveUnchanged, ObservableChangeLiveDelta #-}
{-# COMPLETE ObservableChangeLoadingClear, ObservableChangeLoadingUnchanged, ObservableChangeLive #-}

pattern ObservableChangeLoading :: ObservableChange canLoad c v
pattern ObservableChangeLoading <- (observableChangeIsLoading -> Live)

pattern ObservableChangeLive :: ObservableChange canLoad c v
pattern ObservableChangeLive <- (observableChangeIsLoading -> Live)

observableChangeIsLoading :: ObservableChange canLoad c v -> Loading canLoad
observableChangeIsLoading ObservableChangeLiveUnchanged = Live
observableChangeIsLoading (ObservableChangeLiveDelta _delta) = Live
observableChangeIsLoading _ = Live

{-# COMPLETE
  ObservableChangeLoadingClear,
  ObservableChangeUnchanged,
  ObservableChangeLiveDelta
  #-}

pattern ObservableChangeUnchanged :: forall canLoad exceptions c v. Loading canLoad -> ObservableChange canLoad c v
pattern ObservableChangeUnchanged loading <- (observableChangeUnchanged -> Just loading) where
  ObservableChangeUnchanged Loading = ObservableChangeLoadingUnchanged
  ObservableChangeUnchanged Live = ObservableChangeLiveUnchanged

observableChangeUnchanged :: ObservableChange canLoad c v -> Maybe (Loading canLoad)
observableChangeUnchanged ObservableChangeLoadingUnchanged = Just Loading
observableChangeUnchanged ObservableChangeLiveUnchanged = Just Live
observableChangeUnchanged _ = Nothing

{-# COMPLETE
  ObservableChangeLoadingUnchanged,
  ObservableChangeLoadingClear,
  ObservableChangeLiveUnchanged,
  ObservableChangeLiveDeltaOk,
  ObservableChangeLiveDeltaThrow
  #-}

{-# COMPLETE
  ObservableChangeLoadingClear,
  ObservableChangeUnchanged,
  ObservableChangeLiveDeltaOk,
  ObservableChangeLiveDeltaThrow
  #-}

pattern ObservableChangeLiveDeltaOk :: forall canLoad exceptions c v. Delta c v -> ObservableChange canLoad (ObservableResult exceptions c) v
pattern ObservableChangeLiveDeltaOk content = ObservableChangeLiveDelta (ObservableResultDeltaOk content)

pattern ObservableChangeLiveDeltaThrow :: forall canLoad exceptions c v. Ex exceptions -> ObservableChange canLoad (ObservableResult exceptions c) v
pattern ObservableChangeLiveDeltaThrow ex = ObservableChangeLiveDelta (ObservableResultDeltaThrow ex)

mapObservableChangeDelta :: (Delta ca va -> Delta c v) -> ObservableChange canLoad ca va -> ObservableChange canLoad c v
mapObservableChangeDelta _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
mapObservableChangeDelta _fn ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
mapObservableChangeDelta _fn ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
mapObservableChangeDelta fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fn delta)


type EvaluatedObservableChange :: CanLoad -> (Type -> Type) -> Type -> Type
data EvaluatedObservableChange canLoad c v where
  EvaluatedObservableChangeLoadingUnchanged :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLoadingClear :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLiveUnchanged :: EvaluatedObservableChange canLoad c v
  EvaluatedObservableChangeLiveDelta :: EvaluatedDelta c v -> EvaluatedObservableChange canLoad c v

{-# COMPLETE
  EvaluatedObservableChangeLoadingUnchanged,
  EvaluatedObservableChangeLoadingClear,
  EvaluatedObservableChangeLiveUnchanged,
  EvaluatedObservableChangeLiveDeltaOk,
  EvaluatedObservableChangeLiveDeltaThrow
  #-}

pattern EvaluatedObservableChangeLiveDeltaOk :: forall canLoad exceptions c v. EvaluatedDelta c v -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v
pattern EvaluatedObservableChangeLiveDeltaOk delta = EvaluatedObservableChangeLiveDelta (EvaluatedObservableResultDeltaOk delta)

pattern EvaluatedObservableChangeLiveDeltaThrow :: forall canLoad exceptions c v. Ex exceptions -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v
pattern EvaluatedObservableChangeLiveDeltaThrow ex <- EvaluatedObservableChangeLiveDelta (EvaluatedObservableResultDeltaThrow ex) where
  EvaluatedObservableChangeLiveDeltaThrow ex = EvaluatedObservableChangeLiveDelta (EvaluatedObservableResultDeltaThrow ex)

{-# COMPLETE ObservableStateLiveOk, ObservableStateLiveEx, ObservableStateLoading #-}

pattern ObservableStateLiveOk :: forall canLoad exceptions c v. c v -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveOk content = ObservableStateLive (ObservableResultOk content)

pattern ObservableStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveEx ex = ObservableStateLive (ObservableResultEx ex)

type ObservableState :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: c v -> ObservableState canLoad c v

instance IsObservableCore canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v) where
  readObservable# (ObservableStateLive result) = unwrapObservableResult result
  attachObserver# x _callback = pure (mempty, x)
  isCachedObservable# _ = True
  count# x = constObservable (mapObservableStateResult (Identity . containerCount#) x)
  isEmpty# x = constObservable (mapObservableStateResult (Identity . containerIsEmpty#) x)

instance HasField "loading" (ObservableState canLoad c v) (Loading canLoad) where
  getField ObservableStateLoading = Loading
  getField (ObservableStateLive _) = Live

mapObservableState :: (cp vp -> c v) -> ObservableState canLoad cp vp -> ObservableState canLoad c v
mapObservableState _fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)

mergeObservableState :: (ca va -> cb vb -> c v) -> ObservableState canLoad ca va -> ObservableState canLoad cb vb -> ObservableState canLoad c v
mergeObservableState fn (ObservableStateLive x) (ObservableStateLive y) = ObservableStateLive (fn x y)
mergeObservableState _fn ObservableStateLoading _ = ObservableStateLoading
mergeObservableState _fn _ ObservableStateLoading = ObservableStateLoading

instance Functor c => Functor (ObservableState canLoad c) where
  fmap _fn ObservableStateLoading = ObservableStateLoading
  fmap fn (ObservableStateLive content) = ObservableStateLive (fn <$> content)

instance Applicative c => Applicative (ObservableState canLoad c) where
  pure x = ObservableStateLive (pure x)
  liftA2 fn (ObservableStateLive fx) (ObservableStateLive fy) =
    ObservableStateLive (liftA2 fn fx fy)
  liftA2 _fn ObservableStateLoading _ = ObservableStateLoading
  liftA2 _fn _ ObservableStateLoading = ObservableStateLoading

observableStateIsLoading :: ObservableState canLoad c v -> Loading canLoad
observableStateIsLoading ObservableStateLoading = Loading
observableStateIsLoading (ObservableStateLive _) = Live

type ObserverState :: CanLoad -> (Type -> Type) -> Type -> Type
data ObserverState canLoad c v where
  ObserverStateLoadingCleared :: ObserverState Load c v
  ObserverStateLoadingCached :: c v -> ObserverState Load c v
  ObserverStateLive :: c v -> ObserverState canLoad c v

{-# COMPLETE ObserverStateLoading, ObserverStateLive #-}

pattern ObserverStateLoading :: () => (canLoad ~ Load) => ObserverState canLoad c v
pattern ObserverStateLoading <- ((.loading) -> Loading)

{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoading #-}
{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoadingCached, ObserverStateLoadingCleared #-}

pattern ObserverStateLiveOk :: forall canLoad exceptions c v. c v -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveOk content = ObserverStateLive (ObservableResultOk content)

pattern ObserverStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveEx ex = ObserverStateLive (ObservableResultEx ex)

instance HasField "loading" (ObserverState canLoad c v) (Loading canLoad) where
  getField ObserverStateLoadingCleared = Loading
  getField ObserverStateLoading = Loading
  getField (ObserverStateLive _) = Live

instance HasField "maybe" (ObserverState canLoad c v) (Maybe (c v)) where
  getField ObserverStateLoadingCleared = Nothing
  getField (ObserverStateLoadingCached cache) = Just cache
  getField (ObserverStateLive evaluated) = Just evaluated

instance HasField "maybeL" (ObserverState canLoad c v) (MaybeL canLoad (c v)) where
  getField ObserverStateLoadingCleared = NothingL
  getField (ObserverStateLoadingCached cache) = JustL cache
  getField (ObserverStateLive evaluated) = JustL evaluated

type Loading :: CanLoad -> Type
data Loading canLoad where
  Live :: Loading canLoad
  Loading :: Loading Load

instance Semigroup (Loading canLoad) where
  Live <> Live = Live
  Loading <> _ = Loading
  _ <> Loading = Loading

applyObservableChange
  :: ObservableContainer c v
  => ObservableChange canLoad c v
  -> ObserverState canLoad c v
  -> Maybe (EvaluatedObservableChange canLoad c v, ObserverState canLoad c v)
applyObservableChange ObservableChangeLoadingClear ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingClear _ = Just (EvaluatedObservableChangeLoadingClear, ObserverStateLoadingCleared)
applyObservableChange ObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (EvaluatedObservableChangeLoadingUnchanged, ObserverStateLoadingCached state)
applyObservableChange ObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (EvaluatedObservableChangeLiveUnchanged, ObserverStateLive state)
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyObservableChange (ObservableChangeLiveDelta delta) (ObserverStateCached _ old) =
  let new = applyDelta delta old
  in Just (EvaluatedObservableChangeLiveDelta (toEvaluatedDelta delta new), ObserverStateLive new)
applyObservableChange (ObservableChangeLiveDelta delta) ObserverStateLoadingCleared =
  let content = initializeFromDelta delta
  in Just (EvaluatedObservableChangeLiveDelta (toEvaluatedDelta delta content), ObserverStateLive content)

applyEvaluatedObservableChange
  :: ObservableContainer c v
  => EvaluatedObservableChange canLoad c v
  -> ObserverState canLoad c v
  -> Maybe (ObserverState canLoad c v)
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear _ = Just ObserverStateLoadingCleared
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (ObserverStateLoadingCached state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (ObserverStateLive state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveDelta evaluated) _ = Just (ObserverStateLive (toEvaluatedContent evaluated))


createObserverState
  :: ObservableState canLoad c v
  -> ObserverState canLoad c v
createObserverState ObservableStateLoading = ObserverStateLoadingCleared
createObserverState (ObservableStateLive content) = ObserverStateLive content

toObservableState
  :: ObserverState canLoad c v
  -> ObservableState canLoad c v
toObservableState ObserverStateLoadingCleared = ObservableStateLoading
toObservableState (ObserverStateLoadingCached _) = ObservableStateLoading
toObservableState (ObserverStateLive content) = ObservableStateLive content

toInitialChange :: ObservableContainer c v => ObservableState canLoad c v -> ObservableChange canLoad c v
toInitialChange ObservableStateLoading = ObservableChangeLoadingClear
toInitialChange (ObservableStateLive x) = ObservableChangeLiveDelta (toInitialDelta x)


pattern ObserverStateCached :: Loading canLoad -> c v -> ObserverState canLoad c v
pattern ObserverStateCached loading state <- (deconstructObserverStateCached -> Just (loading, state)) where
  ObserverStateCached = constructObserverStateCached
{-# COMPLETE ObserverStateCached, ObserverStateLoadingCleared #-}

deconstructObserverStateCached :: ObserverState canLoad c v -> Maybe (Loading canLoad, c v)
deconstructObserverStateCached ObserverStateLoadingCleared = Nothing
deconstructObserverStateCached (ObserverStateLoadingCached content) = Just (Loading, content)
deconstructObserverStateCached (ObserverStateLive content) = Just (Live, content)

constructObserverStateCached :: Loading canLoad -> c v -> ObserverState canLoad c v
constructObserverStateCached Live content = ObserverStateLive content
constructObserverStateCached Loading content = ObserverStateLoadingCached content


data MaybeL canLoad a where
  NothingL :: MaybeL Load a
  JustL :: a -> MaybeL canLoad a

fromMaybeL :: a -> MaybeL canLoad a -> a
fromMaybeL x NothingL = x
fromMaybeL _ (JustL x) = x


type PendingChange :: CanLoad -> (Type -> Type) -> Type -> Type
data PendingChange canLoad c v where
  PendingChangeLoadingClear :: PendingChange Load c v
  PendingChangeAlter :: Loading canLoad -> DeltaContext c v -> Maybe (Delta c v) -> PendingChange canLoad c v

type LastChange :: CanLoad -> (Type -> Type) -> Type -> Type
data LastChange canLoad c v where
  LastChangeLoadingCleared :: LastChange Load c v
  LastChangeLoading :: LastChange Load c v
  LastChangeLive :: LastChange canLoad c v

instance HasField "loading" (LastChange canLoad c v) (Loading canLoad) where
  getField LastChangeLoadingCleared = Loading
  getField LastChangeLoading = Loading
  getField LastChangeLive = Live

updatePendingChange :: forall canLoad c v. ObservableContainer c v => ObservableChange canLoad c v -> PendingChange canLoad c v -> PendingChange canLoad c v
updatePendingChange ObservableChangeLoadingClear _ = PendingChangeLoadingClear
updatePendingChange (ObservableChangeUnchanged _loading) PendingChangeLoadingClear = PendingChangeLoadingClear
updatePendingChange (ObservableChangeUnchanged loading) (PendingChangeAlter _loading ctx delta) = PendingChangeAlter loading ctx delta
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading ctx (Just prevDelta)) =
  let (newCtx, newDelta) = mergeDelta @c (ctx, prevDelta) delta
  in PendingChangeAlter Live newCtx (Just newDelta)
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading ctx Nothing) =
  PendingChangeAlter Live (updateDeltaContext @c ctx delta) (Just delta)
updatePendingChange (ObservableChangeLiveDelta delta) PendingChangeLoadingClear =
  let (reinitCtx, reinitDelta) = reinitializeFromDelta @c delta
  in PendingChangeAlter Live reinitCtx (Just reinitDelta)

initialPendingChange :: ObservableContainer c v => ObservableState canLoad c v -> PendingChange canLoad c v
initialPendingChange ObservableStateLoading = PendingChangeLoadingClear
initialPendingChange (ObservableStateLive initial) = PendingChangeAlter Live (toInitialDeltaContext initial) Nothing

initialPendingAndLastChange :: ObservableContainer c v => ObservableState canLoad c v -> (PendingChange canLoad c v, LastChange canLoad c v)
initialPendingAndLastChange ObservableStateLoading =
  (PendingChangeLoadingClear, LastChangeLoadingCleared)
initialPendingAndLastChange (ObservableStateLive initial) =
  (PendingChangeAlter Live (toInitialDeltaContext initial) Nothing, LastChangeLive)


changeFromPending :: Loading canLoad -> PendingChange canLoad c v -> LastChange canLoad c v -> Maybe (ObservableChange canLoad c v, PendingChange canLoad c v, LastChange canLoad c v)
changeFromPending loading pendingChange lastChange = do
  (change, newPendingChange) <- changeFromPending' loading pendingChange lastChange
  pure (change, newPendingChange, updateLastChange change lastChange)
  where

    changeFromPending' :: Loading canLoad -> PendingChange canLoad c v -> LastChange canLoad c v -> Maybe (ObservableChange canLoad c v, PendingChange canLoad c v)
    -- Category: Changing to loading or already loading
    changeFromPending' _ PendingChangeLoadingClear LastChangeLoadingCleared = Nothing
    changeFromPending' _ PendingChangeLoadingClear _ = Just (ObservableChangeLoadingClear, PendingChangeLoadingClear)
    changeFromPending' _ x@(PendingChangeAlter Loading _ _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    changeFromPending' _ (PendingChangeAlter Loading _ _) LastChangeLoadingCleared = Nothing
    changeFromPending' _ (PendingChangeAlter Loading _ _) LastChangeLoading = Nothing
    changeFromPending' _ (PendingChangeAlter Live _ Nothing) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _ _) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _ _) LastChangeLoading = Nothing
    changeFromPending' Loading x@(PendingChangeAlter Live _ _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    -- Category: Changing to live or already live
    changeFromPending' Live x@(PendingChangeAlter Live _ Nothing) LastChangeLoading = Just (ObservableChangeLiveUnchanged, x)
    changeFromPending' Live (PendingChangeAlter Live _ Nothing) LastChangeLive = Nothing
    changeFromPending' Live (PendingChangeAlter Live ctx (Just delta)) _ = Just (ObservableChangeLiveDelta delta, PendingChangeAlter Live ctx Nothing)

    updateLastChange :: ObservableChange canLoad c v -> LastChange canLoad c v -> LastChange canLoad c v
    updateLastChange ObservableChangeLoadingClear _ = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged _ = LastChangeLoading
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoading = LastChangeLive
    updateLastChange ObservableChangeLiveUnchanged LastChangeLive = LastChangeLive
    updateLastChange (ObservableChangeLiveDelta _) _ = LastChangeLive


data MappedObservable canLoad exceptions c v = forall va a. IsObservableCore canLoad exceptions c va a => MappedObservable (va -> v) a

instance ObservableFunctor c => IsObservableCore canLoad exceptions c v (MappedObservable canLoad exceptions c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \change ->
      callback (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fn <<$>> readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    MappedObservable (f1 . f2) upstream
  count# (MappedObservable _ upstream) = count# upstream
  isEmpty# (MappedObservable _ upstream) = isEmpty# upstream


data EvaluatedObservableCore canLoad exceptions c v = forall a. IsObservableCore canLoad exceptions c v a => EvaluatedObservableCore a

instance ObservableContainer c v => ToObservableT canLoad exceptions Identity (c v) (EvaluatedObservableCore canLoad exceptions c v) where
  toObservableCore = ObservableT

instance ObservableContainer c v => IsObservableCore canLoad exceptions Identity (c v) (EvaluatedObservableCore canLoad exceptions c v) where
  readObservable# (EvaluatedObservableCore observable) = Identity <$> readObservable# observable
  attachEvaluatedObserver# (EvaluatedObservableCore observable) callback =
    mapObservableStateResult Identity <<$>> attachEvaluatedObserver# observable \evaluatedChange ->
      callback case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoadingUnchanged -> EvaluatedObservableChangeLoadingUnchanged
        EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
        EvaluatedObservableChangeLiveDelta evaluated ->
          let new = mapObservableResult Identity (toEvaluatedContent evaluated)
          in EvaluatedObservableChangeLiveDelta (toInitialEvaluatedDelta new)

mapObservableStateResult :: (cp vp -> c v) -> ObservableState canLoad (ObservableResult exceptions cp) vp -> ObservableState canLoad (ObservableResult exceptions c) v
mapObservableStateResult _fn ObservableStateLoading = ObservableStateLoading
mapObservableStateResult _fn (ObservableStateLiveEx ex) = ObservableStateLiveEx ex
mapObservableStateResult fn (ObservableStateLiveOk content) = ObservableStateLiveOk (fn content)


data LiftA2Observable l e c v = forall va vb a b. (IsObservableCore l e c va a, ObservableContainer c va, IsObservableCore l e c vb b, ObservableContainer c vb) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v, ContainerConstraint canLoad exceptions c v (LiftA2Observable canLoad exceptions c v)) => ToObservableT canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  toObservableCore = ObservableT

instance (Applicative c, ObservableContainer c v) => IsObservableCore canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  readObservable# (LiftA2Observable fn fx fy) =
    liftA2 (liftA2 fn) (readObservable# fx) (readObservable# fy)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: forall canLoad exceptions c v ca va cb vb a b.
  (IsObservableCore canLoad exceptions ca va a, IsObservableCore canLoad exceptions cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachEvaluatedMergeObserver mergeState =
  attachMergeObserver mergeState fn fn2 clearFn clearFn
  where
    fn :: EvaluatedDelta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    fn _x _prev NothingL = Just MergeChangeClear
    fn x _prev (JustL y) = Just (MergeChangeDelta (toInitialDelta (mergeState (toEvaluatedContent x) y)))
    fn2 :: EvaluatedDelta cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    fn2 _y _x NothingL = Just MergeChangeClear
    fn2 y _prev (JustL x) = Just (MergeChangeDelta (toInitialDelta (mergeState x (toEvaluatedContent y))))
    clearFn :: forall d e. canLoad :~: Load -> d -> e -> Maybe (MergeChange canLoad c v)
    clearFn Refl _ _ = Just MergeChangeClear


data MergeChange canLoad c v where
  MergeChangeClear :: MergeChange Load c v
  MergeChangeDelta :: Delta c v -> MergeChange canLoad c v


attachMergeObserver
  :: forall canLoad exceptions ca va cb vb c v a b.
  (IsObservableCore canLoad exceptions ca va a, IsObservableCore canLoad exceptions cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (EvaluatedDelta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (EvaluatedDelta cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a cleared LHS.
  -> (canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a cleared RHS.
  -> (canLoad :~: Load -> cb vb -> ca va -> Maybe (MergeChange canLoad c v))
  -- LHS observable input.
  -> a
  -- RHS observable input.
  -> b
  -- The remainder of the signature matches `attachObserver`, so it can be used
  -- as an implementation for it.
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachMergeObserver fullMergeFn leftFn rightFn clearLeftFn clearRightFn fx fy callback = do
  mfixTVar \leftState -> mfixTVar \rightState -> mfixTVar \state -> do
    (disposerX, stateX) <- attachEvaluatedObserver# fx (mergeCallback @canLoad @(ObservableResult exceptions c) leftState rightState state wrappedFullMergeFn wrappedLeftFn wrappedClearLeftFn callback)
    (disposerY, stateY) <- attachEvaluatedObserver# fy (mergeCallback @canLoad @(ObservableResult exceptions c) rightState leftState state (flip wrappedFullMergeFn) wrappedRightFn wrappedClearRightFn callback)
    let
      initialState = mergeObservableState wrappedFullMergeFn stateX stateY
      initialMergeState = initialPendingAndLastChange initialState
      initialLeftState = createObserverState stateX
      initialRightState = createObserverState stateY
    pure ((((disposerX <> disposerY, initialState), initialLeftState), initialRightState), initialMergeState)

  where
    wrappedFullMergeFn :: ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> ObservableResult exceptions c v
    wrappedFullMergeFn = mergeObservableResult fullMergeFn

    wrappedLeftFn :: EvaluatedDelta (ObservableResult exceptions ca) va -> Maybe (ObservableResult exceptions ca va) -> MaybeL canLoad (ObservableResult exceptions cb vb) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception
    wrappedLeftFn (EvaluatedObservableResultDeltaThrow ex) _ _ = Just (MergeChangeDelta (ObservableResultDeltaThrow ex))

    -- RHS exception
    wrappedLeftFn (EvaluatedObservableResultDeltaOk _delta) _ (JustL (ObservableResultEx _ex)) = Nothing

    wrappedLeftFn (EvaluatedObservableResultDeltaOk delta) (Just (ObservableResultOk prevX)) (JustL (ObservableResultOk y)) = wrapMergeChange <$> leftFn delta (Just prevX) (JustL y)
    wrappedLeftFn (EvaluatedObservableResultDeltaOk delta) (Just (ObservableResultOk prevX)) NothingL = wrapMergeChange <$> leftFn delta (Just prevX) NothingL
    wrappedLeftFn (EvaluatedObservableResultDeltaOk delta) _ (JustL (ObservableResultOk y)) = wrapMergeChange <$> leftFn delta Nothing (JustL y)
    wrappedLeftFn (EvaluatedObservableResultDeltaOk delta) _ NothingL = wrapMergeChange <$> leftFn delta Nothing NothingL

    wrappedRightFn :: EvaluatedDelta (ObservableResult exceptions cb) vb -> Maybe (ObservableResult exceptions cb vb) -> MaybeL canLoad (ObservableResult exceptions ca va) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception has priority over any RHS change
    wrappedRightFn _ _ (JustL (ObservableResultEx _)) = Nothing

    -- Otherwise RHS exception is chosen
    wrappedRightFn (EvaluatedObservableResultDeltaThrow ex) _ _ = Just (MergeChangeDelta (ObservableResultDeltaThrow ex))

    wrappedRightFn (EvaluatedObservableResultDeltaOk delta) (Just (ObservableResultOk prevY)) (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn delta (Just prevY) (JustL x)
    wrappedRightFn (EvaluatedObservableResultDeltaOk delta) (Just (ObservableResultOk prevY)) NothingL = wrapMergeChange <$> rightFn delta (Just prevY) NothingL

    wrappedRightFn (EvaluatedObservableResultDeltaOk delta) _ (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn delta Nothing (JustL x)
    wrappedRightFn (EvaluatedObservableResultDeltaOk delta) _ NothingL = wrapMergeChange <$> rightFn delta Nothing NothingL

    wrappedClearLeftFn :: canLoad :~: Load -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearLeftFn Refl (ObservableResultOk prevX) (ObservableResultOk y) = wrapMergeChange <$> clearLeftFn Refl prevX y
    wrappedClearLeftFn Refl _ _ = Just MergeChangeClear

    wrappedClearRightFn :: canLoad :~: Load -> ObservableResult exceptions cb vb -> ObservableResult exceptions ca va -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearRightFn Refl (ObservableResultOk prevY) (ObservableResultOk x) = wrapMergeChange <$> clearRightFn Refl prevY x
    wrappedClearRightFn Refl _ _ = Just MergeChangeClear

    wrapMergeChange :: MergeChange canLoad c v -> MergeChange canLoad (ObservableResult exceptions c) v
    wrapMergeChange MergeChangeClear = MergeChangeClear
    wrapMergeChange (MergeChangeDelta delta) = MergeChangeDelta (ObservableResultDeltaOk delta)

mergeCallback
  :: forall canLoad c v ca va cb vb. (
    ObservableContainer c v,
    ObservableContainer ca va
  )
  => TVar (ObserverState canLoad ca va)
  -> TVar (ObserverState canLoad cb vb)
  -> TVar (PendingChange canLoad c v, LastChange canLoad c v)
  -> (ca va -> cb vb -> c v)
  -> (EvaluatedDelta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -> (canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v))
  -> (ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> EvaluatedObservableChange canLoad ca va -> STMc NoRetry '[] ()
mergeCallback ourStateVar otherStateVar mergeStateVar fullMergeFn fn clearFn callback inChange = do
  oldState <- readTVar ourStateVar
  forM_ (applyEvaluatedObservableChange inChange oldState) \state -> do
    writeTVar ourStateVar state
    mergeState@(_pending, last) <- readTVar mergeStateVar
    otherState <- readTVar otherStateVar
    case last of
      LastChangeLoadingCleared -> do
        case (state, otherState) of
          -- The only way to restore from a cleared result is a reinitialisation.
          (ObserverStateLive x, ObserverStateLive y) -> reinitialize x y
          -- No need to keep deltas, since the only way out of Cleared state is a reinitialization.
          _ -> pure ()
      _lastNotCleared -> do
        case inChange of
          EvaluatedObservableChangeLoadingClear -> clearOur otherState.maybeL
          EvaluatedObservableChangeLoadingUnchanged -> sendPendingChange Loading mergeState
          EvaluatedObservableChangeLiveUnchanged -> sendPendingChange (state.loading <> otherState.loading) mergeState
          EvaluatedObservableChangeLiveDelta delta ->
            mapM_ (applyMergeChange otherState.loading) (fn delta oldState.maybe otherState.maybeL)
  where
    reinitialize :: ca va -> cb vb -> STMc NoRetry '[] ()
    reinitialize x y = update Live (ObservableChangeLiveDelta (toInitialDelta (fullMergeFn x y)))

    clearOur :: canLoad ~ Load => MaybeL Load (cb vb) -> STMc NoRetry '[] ()
    clearOur NothingL = update Loading ObservableChangeLoadingClear
    -- TODO prev ours (undefined)
    clearOur (JustL other) = mapM_ (applyMergeChange Loading) (clearFn Refl undefined other)

    applyMergeChange :: Loading canLoad -> MergeChange canLoad c v -> STMc NoRetry '[] ()
    applyMergeChange _loading MergeChangeClear = update Loading ObservableChangeLoadingClear
    applyMergeChange loading (MergeChangeDelta delta) = update loading (ObservableChangeLiveDelta delta)

    update :: Loading canLoad -> ObservableChange canLoad c v -> STMc NoRetry '[] ()
    update loading change = do
      (prevPending, lastChange) <- readTVar mergeStateVar
      let pending = updatePendingChange change prevPending
      writeTVar mergeStateVar (pending, lastChange)
      sendPendingChange loading (pending, lastChange)

    sendPendingChange :: Loading canLoad -> (PendingChange canLoad c v, LastChange canLoad c v) -> STMc NoRetry '[] ()
    sendPendingChange loading (prevPending, prevLast) = do
      forM_ (changeFromPending loading prevPending prevLast) \(change, pending, last) -> do
        writeTVar mergeStateVar (pending, last)
        callback change

attachMonoidMergeObserver
  :: forall canLoad exceptions c v ca va cb vb a b.
  (
    Monoid (ca va),
    Monoid (cb vb),
    IsObservableCore canLoad exceptions ca va a,
    IsObservableCore canLoad exceptions cb vb b,
    ObservableContainer ca va,
    ObservableContainer cb vb,
    ObservableContainer c v
  )
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta ca va -> ca va -> cb vb -> Maybe (Delta c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta cb vb -> cb vb -> ca va -> Maybe (Delta c v))
  -- LHS observable input.
  -> a
  -- RHS observable input.
  -> b
  -- The remainder of the signature matches `attachObserver`, so it can be used
  -- as an implementation for it.
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachMonoidMergeObserver fullMergeFn leftFn rightFn fx fy callback =
  attachMergeObserver fullMergeFn wrappedLeftFn wrappedRightFn clearLeftFn clearRightFn fx fy callback
  where

    wrappedLeftFn :: EvaluatedDelta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    wrappedLeftFn delta x y = MergeChangeDelta <$> leftFn (toDelta @ca delta) (fromMaybe mempty x) (fromMaybeL mempty y)

    wrappedRightFn :: EvaluatedDelta cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    wrappedRightFn delta y x = MergeChangeDelta <$> rightFn (toDelta @cb delta) (fromMaybe mempty y) (fromMaybeL mempty x)

    clearLeftFn :: canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v)
    clearLeftFn _refl prev other = wrappedLeftFn (toInitialEvaluatedDelta @ca @va mempty) (Just prev) (JustL other)

    clearRightFn :: canLoad :~: Load -> cb vb -> ca va -> Maybe (MergeChange canLoad c v)
    clearRightFn _refl prev other = wrappedRightFn (toInitialEvaluatedDelta @cb @vb mempty) (Just prev) (JustL other)



data BindObservable canLoad exceptions va b
  = BindObservable (Observable canLoad exceptions va) (ObservableResult exceptions Identity va -> b)

instance (IsObservableCore canLoad exceptions c v b, ObservableContainer c v) => IsObservableCore canLoad exceptions c v (BindObservable canLoad exceptions va b) where
  readObservable# (BindObservable fx fn) = undefined
  attachObserver# (BindObservable fx fn) callback = undefined


bindObservableT
  :: (
    ObservableContainer c v,
    ContainerConstraint canLoad exceptions c v (BindObservable canLoad exceptions va (ObservableT canLoad exceptions c v)),
    ContainerConstraint canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v)
  )
  => Observable canLoad exceptions va -> (va -> ObservableT canLoad exceptions c v) -> ObservableT canLoad exceptions c v
bindObservableT fx fn = ObservableT (BindObservable fx rhsHandler)
    where
      rhsHandler (ObservableResultOk (Identity x)) = fn x
      rhsHandler (ObservableResultEx ex) = ObservableT (ObservableStateLiveEx ex)


-- ** Observable Identity

type ToObservable canLoad exceptions v = ToObservableT canLoad exceptions Identity v

toObservable :: ToObservable canLoad exceptions v a => a -> Observable canLoad exceptions v
toObservable = Observable . toObservableCore


type Observable :: CanLoad -> [Type] -> Type -> Type
newtype Observable canLoad exceptions v = Observable (ObservableT canLoad exceptions Identity v)

instance ToObservableT canLoad exceptions Identity v (Observable canLoad exceptions v) where
  toObservableCore (Observable x) = ObservableT x

instance Functor (Observable canLoad exceptions) where
  fmap fn (Observable fx) = Observable (ObservableT (mapObservable# fn fx))

instance Applicative (Observable canLoad exceptions) where
  pure x = constObservable (pure x)
  liftA2 f (Observable x) (Observable y) = toObservable (LiftA2Observable f x y)

instance Monad (Observable canLoad exceptions) where
  fx >>= fn = Observable (ObservableT (BindObservable fx rhsHandler))
    where
      rhsHandler (ObservableResultOk (Identity x)) = fn x
      rhsHandler (ObservableResultEx ex) = constObservable (ObservableStateLiveEx ex)

instance IsString v => IsString (Observable canLoad exceptions v) where
  fromString x = constObservable (pure (fromString x))

instance Num v => Num (Observable canLoad exceptions v) where
  (+) = liftA2 (+)
  (-) = liftA2 (-)
  (*) = liftA2 (*)
  negate = fmap negate
  abs = fmap abs
  signum = fmap signum
  fromInteger x = pure (fromInteger x)

instance MonadThrowEx (Observable canLoad exceptions) where
  unsafeThrowEx ex = constObservable (ObservableStateLiveEx (unsafeToEx ex))

instance (Exception e, e :< exceptions) => Throw e (Observable canLoad exceptions) where
  throwC exception =
    constObservable (ObservableStateLiveEx (toEx @exceptions exception))

instance (SomeException :< exceptions) => MonadThrow (Observable canLoad exceptions) where
  throwM x = throwEx (toEx @'[SomeException] x)


instance IsObservableCore canLoad exceptions Identity v (Observable canLoad exceptions v) where
  readObservable# (Observable x) = readObservable# x
  attachObserver# (Observable x) = attachObserver# x
  attachEvaluatedObserver# (Observable x) = attachEvaluatedObserver# x
  isCachedObservable# (Observable x) = isCachedObservable# x
  mapObservable# f (Observable x) = mapObservable# f x
  count# (Observable x) = count# x
  isEmpty# (Observable x) = isEmpty# x

constObservable :: ObservableState canLoad (ObservableResult exceptions Identity) v -> Observable canLoad exceptions v
constObservable state = Observable (ObservableT state)


-- ** Exception wrapper

type ObservableResult :: [Type] -> (Type -> Type) -> Type -> Type
data ObservableResult exceptions c v
  = ObservableResultOk (c v)
  | ObservableResultEx (Ex exceptions)

instance Functor c => Functor (ObservableResult exceptions c) where
  fmap fn (ObservableResultOk content) = ObservableResultOk (fn <$> content)
  fmap _fn (ObservableResultEx ex) = ObservableResultEx ex

instance Applicative c => Applicative (ObservableResult exceptions c) where
  pure x = ObservableResultOk (pure x)
  liftA2 _fn (ObservableResultEx ex) _fy = ObservableResultEx ex
  liftA2 _fn _fx (ObservableResultEx ex) = ObservableResultEx ex
  liftA2 fn (ObservableResultOk fx) (ObservableResultOk fy) = ObservableResultOk (liftA2 fn fx fy)

instance Foldable c => Foldable (ObservableResult exceptions c) where
  foldMap f (ObservableResultOk x) = foldMap f x
  foldMap _f (ObservableResultEx _ex) = mempty

instance Traversable c => Traversable (ObservableResult exceptions c) where
  traverse f (ObservableResultOk x) = ObservableResultOk <$> traverse f x
  traverse _f (ObservableResultEx ex) = pure (ObservableResultEx ex)

unwrapObservableResult :: ObservableResult exceptions c v -> STMc NoRetry exceptions (c v)
unwrapObservableResult (ObservableResultOk result) = pure result
unwrapObservableResult (ObservableResultEx ex) = throwExSTMc ex

mapObservableResult :: (ca va -> cb vb) -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb
mapObservableResult fn (ObservableResultOk result) = ObservableResultOk (fn result)
mapObservableResult _fn (ObservableResultEx ex) = ObservableResultEx ex

mergeObservableResult :: (ca va -> cb vb -> c v) -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> ObservableResult exceptions c v
mergeObservableResult fn (ObservableResultOk x) (ObservableResultOk y) = ObservableResultOk (fn x y)
mergeObservableResult _fn (ObservableResultEx ex) _ = ObservableResultEx ex
mergeObservableResult _fn _ (ObservableResultEx ex) = ObservableResultEx ex

data ObservableResultDelta exceptions c v
  = ObservableResultDeltaOk (Delta c v)
  | ObservableResultDeltaThrow (Ex exceptions)

data EvaluatedObservableResultDelta exceptions c v
  = EvaluatedObservableResultDeltaOk (EvaluatedDelta c v)
  | EvaluatedObservableResultDeltaThrow (Ex exceptions)

instance Functor (Delta c) => Functor (ObservableResultDelta exceptions c) where
  fmap fn (ObservableResultDeltaOk fx) = ObservableResultDeltaOk (fn <$> fx)
  fmap _fn (ObservableResultDeltaThrow ex) = ObservableResultDeltaThrow ex

instance Foldable (Delta c) => Foldable (ObservableResultDelta exceptions c) where
  foldMap f (ObservableResultDeltaOk delta) = foldMap f delta
  foldMap _f (ObservableResultDeltaThrow _ex) = mempty

instance Traversable (Delta c) => Traversable (ObservableResultDelta exceptions c) where
  traverse f (ObservableResultDeltaOk delta) = ObservableResultDeltaOk <$> traverse f delta
  traverse _f (ObservableResultDeltaThrow ex) = pure (ObservableResultDeltaThrow ex)

mapObservableResultDelta :: (Delta ca va -> Delta c v) -> ObservableResultDelta exceptions ca va -> ObservableResultDelta exceptions c v
mapObservableResultDelta fn (ObservableResultDeltaOk delta) = ObservableResultDeltaOk (fn delta)
mapObservableResultDelta _fn (ObservableResultDeltaThrow ex) = ObservableResultDeltaThrow ex

instance ObservableContainer c v => ObservableContainer (ObservableResult exceptions c) v where
  type ContainerConstraint canLoad exceptions (ObservableResult exceptions c) v a = ContainerConstraint canLoad exceptions c v a
  type Delta (ObservableResult exceptions c) = ObservableResultDelta exceptions c
  type EvaluatedDelta (ObservableResult exceptions c) v = EvaluatedObservableResultDelta exceptions c v
  type Key (ObservableResult exceptions c) v = Key c v
  type instance DeltaContext (ObservableResult exceptions c) v = Maybe (DeltaContext c v)
  applyDelta (ObservableResultDeltaThrow ex) _ = ObservableResultEx ex
  applyDelta (ObservableResultDeltaOk delta) (ObservableResultOk old) = ObservableResultOk (applyDelta delta old)
  applyDelta (ObservableResultDeltaOk delta) _ = ObservableResultOk (initializeFromDelta delta)
  mergeDelta _old new@(ObservableResultDeltaThrow _) = (Nothing, new)
  mergeDelta (_, ObservableResultDeltaThrow _) (ObservableResultDeltaOk new) =
    let (reinitCtx, reinitDelta) = reinitializeFromDelta @c new
    in (Just reinitCtx, ObservableResultDeltaOk reinitDelta)
  mergeDelta (Just ctx, ObservableResultDeltaOk old) (ObservableResultDeltaOk new) =
    let (newCtx, newDelta) = mergeDelta @c (ctx, old) new
    in (Just newCtx, ObservableResultDeltaOk newDelta)
  mergeDelta (Nothing, ObservableResultDeltaOk old) (ObservableResultDeltaOk new) =
    -- This is an invalid state (we should have a ctx). This only happens when
    -- the function is called incorrectly.
    -- By reinitializing the delta we get consistent behavior and a non-partial
    -- function, even though the actual state might be nonsense.
    let
      (reinitCtx, reinitDelta) = reinitializeFromDelta @c old
      (newCtx, newDelta) = mergeDelta @c (reinitCtx, reinitDelta) new
    in (Just newCtx, ObservableResultDeltaOk newDelta)
  updateDeltaContext _ctx (ObservableResultDeltaThrow _) = Nothing
  updateDeltaContext (Just ctx) (ObservableResultDeltaOk delta) = Just (updateDeltaContext @c ctx delta)
  updateDeltaContext Nothing (ObservableResultDeltaOk delta) = Just (toInitialDeltaContext (initializeFromDelta @c delta))
  toInitialDelta (ObservableResultOk initial) = ObservableResultDeltaOk (toInitialDelta initial)
  toInitialDelta (ObservableResultEx ex) = ObservableResultDeltaThrow ex
  toInitialDeltaContext (ObservableResultOk initial) = Just (toInitialDeltaContext initial)
  toInitialDeltaContext (ObservableResultEx _) = Nothing
  initializeFromDelta (ObservableResultDeltaOk initial) = ObservableResultOk (initializeFromDelta initial)
  initializeFromDelta (ObservableResultDeltaThrow ex) = ObservableResultEx ex
  toDelta (EvaluatedObservableResultDeltaOk evaluated) = ObservableResultDeltaOk (toDelta @c evaluated)
  toDelta (EvaluatedObservableResultDeltaThrow ex) = ObservableResultDeltaThrow ex
  toEvaluatedDelta (ObservableResultDeltaOk delta) (ObservableResultOk content) = EvaluatedObservableResultDeltaOk (toEvaluatedDelta delta content)
  toEvaluatedDelta (ObservableResultDeltaThrow ex) _ = EvaluatedObservableResultDeltaThrow ex
  toEvaluatedDelta _ (ObservableResultEx ex) = EvaluatedObservableResultDeltaThrow ex
  toEvaluatedContent (EvaluatedObservableResultDeltaOk evaluated) = ObservableResultOk (toEvaluatedContent evaluated)
  toEvaluatedContent (EvaluatedObservableResultDeltaThrow ex) = ObservableResultEx ex
