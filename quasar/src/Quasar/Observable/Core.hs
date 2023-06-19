{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
  Observable(..),
  constObservable,
  ToObservable(..),

  readObservable,
  attachObserver,
  attachEvaluatedObserver,
  mapObservable,
  isCachedObservable,

  mapObservableContent,
  evaluateObservable,

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanLoad(..),
#else
  CanLoad,
  Load,
  NoLoad,
#endif


  IsObservableCore(..),
  ObservableCore(..),
  ObservableContainer(..),

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
  Selector(..),
  mapSelector,

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
  emptyPendingChange,
  initialLastChange,
  changeFromPending,

  -- *** Merging changes
  MergeChange(..),
  MaybeL(..),
  attachMergeObserver,
  attachMonoidMergeObserver,
  attachEvaluatedMergeObserver,

  -- * Identity observable (single value without partial updates)
  ObservableI,
  ToObservableI,
  toObservableI,

  -- * ObservableMap
  ObservableMap,
  ToObservableMap,
  toObservableMap,
  ObservableMapDelta(..),
  ObservableMapOperation(..),

  -- * ObservableSet
  ObservableSet,
  ToObservableSet,
  toObservableSet,
  ObservableSetDelta(..),
  ObservableSetOperation(..),
) where

import Control.Applicative
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Catch.Pure (MonadThrow(..))
import Control.Monad.Except
import Data.Binary (Binary)
import Data.Functor.Identity (Identity(..))
import Data.Map.Merge.Strict qualified as Map
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (IsString(..))
import Data.Type.Equality ((:~:)(Refl))
import GHC.Records (HasField(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type ToObservable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c v => ToObservable canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  toObservable :: a -> Observable canLoad exceptions c v

type IsObservableCore :: CanLoad -> (Type -> Type) -> Type -> Type -> Constraint
class IsObservableCore canLoad c v a | a -> canLoad, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable#
    :: canLoad ~ NoLoad
    => a
    -> STMc NoRetry '[] (c v)

  attachObserver#
    :: ObservableContainer c v
    => a
    -> (ObservableChange canLoad c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad c v)
  attachObserver# x callback = attachEvaluatedObserver# x \evaluatedChange ->
    callback case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveDelta delta _ -> ObservableChangeLiveDelta delta

  attachEvaluatedObserver#
    :: ObservableContainer c v
    => a
    -> (EvaluatedObservableChange canLoad c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad c v)
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

  mapObservable# :: ObservableFunctor c => (v -> n) -> a -> ObservableCore canLoad c n
  mapObservable# f x = ObservableCore (MappedObservable f x)

  mapObservableContent#
    :: (ObservableContainer c v)
    => (c v -> ca va)
    -> a
    -> ObservableCore canLoad ca va
  mapObservableContent# f x = ObservableCore (MappedStateObservable f x)

  count# :: ObservableContainer c v => a -> ObservableI canLoad (ContainerExceptions c) Int64
  count# x = Observable (mapObservableContent# containerCount# x)

  isEmpty# :: ObservableContainer c v => a -> ObservableI canLoad (ContainerExceptions c) Bool
  isEmpty# x = Observable (mapObservableContent# containerIsEmpty# x)

  lookupKey# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (ContainerExceptions c) (Maybe (Key c v))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (ContainerExceptions c) (Maybe (Key c v, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (ContainerExceptions c) (Maybe v)
  lookupValue# x selector = snd <<$>> lookupItem# x selector

  --query# :: a -> ObservableList canLoad (Bounds c v) -> ObservableCore canLoad c v
  --query# = undefined

--query :: ToObservable canLoad exceptions c v a => a -> ObservableList canLoad (Bounds c v) -> Observable canLoad exceptions c v
--query = undefined

type Bounds c v = (Bound c v, Bound c v)

data Bound c v
  = ExcludingBound (Key c v)
  | IncludingBound (Key c v)
  | NoBound

data Selector c v
  = Min
  | Max
  | Key (Key c v)

mapSelector :: (Key ca va -> Key c v) -> Selector ca va -> Selector c v
mapSelector _fn Min = Min
mapSelector _fn Max = Max
mapSelector fn (Key key) = Key (fn key)

readObservable
  :: forall exceptions c v m a.
  (ToObservable NoLoad exceptions c v a, MonadSTMc NoRetry exceptions m)
  => a -> m (c v)
readObservable x = liftSTMc @NoRetry @exceptions do
  result <- liftSTMc @NoRetry @'[] (readObservable# (toObservable x))
  unwrapObservableResult result

attachObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachObserver x callback = liftSTMc $ attachObserver# (toObservable x) callback

attachEvaluatedObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachEvaluatedObserver x callback = liftSTMc do
  attachEvaluatedObserver# (toObservable x) callback

isCachedObservable :: ToObservable canLoad exceptions c v a => a -> Bool
isCachedObservable x = isCachedObservable# (toObservable x)

mapObservable :: (ObservableFunctor c, ToObservable canLoad exceptions c v a) => (v -> va) -> a -> Observable canLoad exceptions c va
mapObservable fn x = Observable (mapObservable# fn (toObservable x))

evaluateObservable :: ToObservable canLoad exceptions c v a => a -> Observable canLoad exceptions Identity (c v)
evaluateObservable x = mapObservableContent Identity x

evaluateObservableCore :: (IsObservableCore canLoad c v a, ObservableContainer c v) => a -> Observable canLoad exceptions Identity (c v)
evaluateObservableCore x = observableFromCore (mapObservableContent# Identity x)

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanLoad = Load | NoLoad
#else
data CanLoad = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad
#endif


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type Delta c :: Type -> Type
  type Key c v
  type ContainerExceptions c :: [Type]
  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: Delta c v -> Delta c v -> Delta c v
  -- | Produce a delta from a content. The delta replaces any previous content when
  -- applied.
  toInitialDelta :: c v -> Delta c v
  initializeFromDelta :: Delta c v -> c v
  containerCount# :: c v -> ObservableResult (ContainerExceptions c) Identity Int64
  containerIsEmpty# :: c v -> ObservableResult (ContainerExceptions c) Identity Bool

instance ObservableContainer Identity v where
  type Delta Identity = Identity
  type Key Identity v = ()
  type ContainerExceptions Identity = '[]
  applyDelta new _ = new
  mergeDelta _ new = new
  toInitialDelta = id
  initializeFromDelta = id
  containerCount# _ = pure 1
  containerIsEmpty# _ = pure False


type ObservableCore :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableCore canLoad c v = forall a. IsObservableCore canLoad c v a => ObservableCore a

instance ObservableContainer c v => ToObservable canLoad exceptions c v (ObservableCore canLoad (ObservableResult exceptions c) v) where
  toObservable = Observable

instance IsObservableCore canLoad c v (ObservableCore canLoad c v) where
  readObservable# (ObservableCore x) = readObservable# x
  attachObserver# (ObservableCore x) = attachObserver# x
  attachEvaluatedObserver# (ObservableCore x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableCore x) = isCachedObservable# x
  mapObservable# f (ObservableCore x) = mapObservable# f x
  mapObservableContent# f (ObservableCore x) = mapObservableContent# f x
  count# (ObservableCore x) = count# x
  isEmpty# (ObservableCore x) = isEmpty# x
  lookupKey# (ObservableCore x) = lookupKey# x
  lookupItem# (ObservableCore x) = lookupItem# x
  lookupValue# (ObservableCore x) = lookupValue# x

instance ObservableFunctor c => Functor (ObservableCore canLoad c) where
  fmap = mapObservable#

constObservableCore :: ObservableState canLoad c v -> ObservableCore canLoad c v
constObservableCore state = ObservableCore state

constObservable :: ObservableState canLoad (ObservableResult exceptions c) v -> Observable canLoad exceptions c v
constObservable state = Observable (constObservableCore state)

type Observable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
newtype Observable canLoad exceptions c v = Observable (ObservableCore canLoad (ObservableResult exceptions c) v)

instance ObservableContainer c v => ToObservable canLoad exceptions c v (Observable canLoad exceptions c v) where
  toObservable = id

instance IsObservableCore canLoad (ObservableResult exceptions c) v (Observable canLoad exceptions c v) where
  readObservable# (Observable x) = readObservable# x
  attachObserver# (Observable x) = attachObserver# x
  attachEvaluatedObserver# (Observable x) = attachEvaluatedObserver# x
  isCachedObservable# (Observable x) = isCachedObservable# x
  mapObservable# f (Observable x) = mapObservable# f x
  mapObservableContent# f (Observable x) = mapObservableContent# f x
  count# (Observable x) = count# x
  isEmpty# (Observable x) = isEmpty# x
  lookupKey# (Observable x) = lookupKey# x
  lookupItem# (Observable x) = lookupItem# x
  lookupValue# (Observable x) = lookupValue# x

type ObservableFunctor c = (Functor c, Functor (Delta c), forall v. ObservableContainer c v)

instance ObservableFunctor c => Functor (Observable canLoad exceptions c) where
  fmap = mapObservable

instance (IsString v, Applicative c) => IsString (Observable canLoad exceptions c v) where
  fromString x = constObservable (pure (fromString x))

instance (Num v, Applicative (Observable canLoad exceptions c)) => Num (Observable canLoad exceptions c v) where
  (+) = liftA2 (+)
  (-) = liftA2 (-)
  (*) = liftA2 (*)
  negate = fmap negate
  abs = fmap abs
  signum = fmap signum
  fromInteger x = pure (fromInteger x)

instance Monad (Observable canLoad exceptions c) => MonadThrowEx (Observable canLoad exceptions c) where
  unsafeThrowEx ex = constObservable (ObservableStateLiveEx (unsafeToEx ex))

instance (Exception e, e :< exceptions, Monad (Observable canLoad exceptions c)) => Throw e (Observable canLoad exceptions c) where
  throwC exception =
    constObservable (ObservableStateLiveEx (toEx @exceptions exception))

instance (SomeException :< exceptions, Monad (Observable canLoad exceptions c)) => MonadThrow (Observable canLoad exceptions c) where
  throwM x = throwEx (toEx @'[SomeException] x)


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
  EvaluatedObservableChangeLiveDelta :: Delta c v -> c v -> EvaluatedObservableChange canLoad c v

instance (Functor c, Functor (Delta c)) => Functor (EvaluatedObservableChange canLoad c) where
  fmap _fn EvaluatedObservableChangeLoadingUnchanged =
    EvaluatedObservableChangeLoadingUnchanged
  fmap _fn EvaluatedObservableChangeLoadingClear =
    EvaluatedObservableChangeLoadingClear
  fmap _fn EvaluatedObservableChangeLiveUnchanged =
    EvaluatedObservableChangeLiveUnchanged
  fmap fn (EvaluatedObservableChangeLiveDelta delta evaluated) =
    EvaluatedObservableChangeLiveDelta (fn <$> delta) (fn <$> evaluated)

{-# COMPLETE
  EvaluatedObservableChangeLoadingUnchanged,
  EvaluatedObservableChangeLoadingClear,
  EvaluatedObservableChangeLiveUnchanged,
  EvaluatedObservableChangeLiveDeltaOk,
  EvaluatedObservableChangeLiveDeltaThrow
  #-}

pattern EvaluatedObservableChangeLiveDeltaOk :: forall canLoad exceptions c v. Delta c v -> c v -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v
pattern EvaluatedObservableChangeLiveDeltaOk delta evaluated = EvaluatedObservableChangeLiveDelta (ObservableResultDeltaOk delta) (ObservableResultOk evaluated)

pattern EvaluatedObservableChangeLiveDeltaThrow :: forall canLoad exceptions c v. Ex exceptions -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v
pattern EvaluatedObservableChangeLiveDeltaThrow ex <- EvaluatedObservableChangeLiveDelta (ObservableResultDeltaThrow ex) _ where
  EvaluatedObservableChangeLiveDeltaThrow ex = EvaluatedObservableChangeLiveDelta (ObservableResultDeltaThrow ex) (ObservableResultEx ex)

{-# COMPLETE ObservableStateLiveOk, ObservableStateLiveEx, ObservableStateLoading #-}

pattern ObservableStateLiveOk :: forall canLoad exceptions c v. c v -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveOk content = ObservableStateLive (ObservableResultOk content)

pattern ObservableStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveEx ex = ObservableStateLive (ObservableResultEx ex)

type ObservableState :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: c v -> ObservableState canLoad c v

instance IsObservableCore canLoad c v (ObservableState canLoad c v) where
  readObservable# (ObservableStateLive x) = pure x
  attachObserver# x _callback = pure (mempty, x)
  count# x = constObservable (mapObservableState containerCount# x)
  isEmpty# x = constObservable (mapObservableState containerIsEmpty# x)

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
  in Just (EvaluatedObservableChangeLiveDelta delta new, ObserverStateLive new)
applyObservableChange (ObservableChangeLiveDelta delta) _ =
  let evaluated = initializeFromDelta delta
  in Just (EvaluatedObservableChangeLiveDelta delta evaluated, ObserverStateLive evaluated)

applyEvaluatedObservableChange
  :: EvaluatedObservableChange canLoad c v
  -> ObserverState canLoad c v
  -> Maybe (ObserverState canLoad c v)
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear _ = Just ObserverStateLoadingCleared
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (ObserverStateLoadingCached state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (ObserverStateLive state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveDelta _delta evaluated) _ = Just (ObserverStateLive evaluated)


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
  PendingChangeAlter :: Loading canLoad -> Maybe (Delta c v) -> PendingChange canLoad c v

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
updatePendingChange (ObservableChangeUnchanged loading) (PendingChangeAlter _loading delta) = PendingChangeAlter loading delta
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading (Just prevDelta)) =
  PendingChangeAlter Live (Just (mergeDelta @c prevDelta delta))
updatePendingChange (ObservableChangeLiveDelta delta) _ = PendingChangeAlter Live (Just delta)

emptyPendingChange :: Loading canLoad -> PendingChange canLoad c v
emptyPendingChange loading = PendingChangeAlter loading Nothing

initialLastChange :: Loading canLoad -> LastChange canLoad c v
initialLastChange Loading = LastChangeLoadingCleared
initialLastChange Live = LastChangeLive


changeFromPending :: Loading canLoad -> PendingChange canLoad c v -> LastChange canLoad c v -> Maybe (ObservableChange canLoad c v, PendingChange canLoad c v, LastChange canLoad c v)
changeFromPending loading pendingChange lastChange = do
  (change, newPendingChange) <- changeFromPending' loading pendingChange lastChange
  pure (change, newPendingChange, updateLastChange change lastChange)
  where

    changeFromPending' :: Loading canLoad -> PendingChange canLoad c v -> LastChange canLoad c v -> Maybe (ObservableChange canLoad c v, PendingChange canLoad c v)
    -- Category: Changing to loading or already loading
    changeFromPending' _ PendingChangeLoadingClear LastChangeLoadingCleared = Nothing
    changeFromPending' _ PendingChangeLoadingClear _ = Just (ObservableChangeLoadingClear, emptyPendingChange Loading)
    changeFromPending' _ x@(PendingChangeAlter Loading _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    changeFromPending' _ (PendingChangeAlter Loading _) LastChangeLoadingCleared = Nothing
    changeFromPending' _ (PendingChangeAlter Loading _) LastChangeLoading = Nothing
    changeFromPending' _ (PendingChangeAlter Live Nothing) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _) LastChangeLoading = Nothing
    changeFromPending' Loading x@(PendingChangeAlter Live _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    -- Category: Changing to live or already live
    changeFromPending' Live (PendingChangeAlter Live Nothing) LastChangeLoading = Just (ObservableChangeLiveUnchanged, emptyPendingChange Live)
    changeFromPending' Live (PendingChangeAlter Live Nothing) LastChangeLive = Nothing
    changeFromPending' Live (PendingChangeAlter Live (Just delta)) _ = Just (ObservableChangeLiveDelta delta, emptyPendingChange Live)

    updateLastChange :: ObservableChange canLoad c v -> LastChange canLoad c v -> LastChange canLoad c v
    updateLastChange ObservableChangeLoadingClear _ = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged _ = LastChangeLoading
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoading = LastChangeLive
    updateLastChange ObservableChangeLiveUnchanged LastChangeLive = LastChangeLive
    updateLastChange (ObservableChangeLiveDelta _) _ = LastChangeLive


data MappedObservable canLoad c v = forall va a. IsObservableCore canLoad c va a => MappedObservable (va -> v) a

instance ObservableFunctor c => IsObservableCore canLoad c v (MappedObservable canLoad c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \change ->
      callback (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fn <<$>> readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    ObservableCore $ MappedObservable (f1 . f2) upstream
  count# (MappedObservable _ upstream) = count# upstream
  isEmpty# (MappedObservable _ upstream) = isEmpty# upstream


data MappedStateObservable canLoad c v = forall d p a. (IsObservableCore canLoad d p a, ObservableContainer d p) => MappedStateObservable (d p -> c v) a

instance IsObservableCore canLoad c v (MappedStateObservable canLoad c v) where
  attachEvaluatedObserver# (MappedStateObservable fn observable) callback =
    fmap2 (mapObservableState fn) $ attachEvaluatedObserver# observable \evaluatedChange ->
      callback case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoadingUnchanged -> EvaluatedObservableChangeLoadingUnchanged
        EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
        EvaluatedObservableChangeLiveDelta _delta evaluated ->
          let new = fn evaluated
          in EvaluatedObservableChangeLiveDelta (toInitialDelta new) new

  readObservable# (MappedStateObservable fn observable) =
    fn <$> readObservable# observable

  mapObservable# f1 (MappedStateObservable f2 observable) =
    ObservableCore (MappedStateObservable (fmap f1 . f2) observable)

  mapObservableContent# f1 (MappedStateObservable f2 observable) =
    ObservableCore (MappedStateObservable (f1 . f2) observable)

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapObservableContent :: (ToObservable canLoad exceptions d p a, ObservableContainer c v) => (d p -> c v) -> a -> Observable canLoad exceptions c v
mapObservableContent fn x = toObservable (mapObservableContent# (mapObservableResult fn) (toObservable x))

mapObservableResultState :: (cp vp -> c v) -> ObservableState canLoad (ObservableResult exceptions cp) vp -> ObservableState canLoad (ObservableResult exceptions c) v
mapObservableResultState _fn ObservableStateLoading = ObservableStateLoading
mapObservableResultState _fn (ObservableStateLiveEx ex) = ObservableStateLiveEx ex
mapObservableResultState fn (ObservableStateLiveOk content) = ObservableStateLiveOk (fn content)


data LiftA2Observable l c v = forall va vb a b. (IsObservableCore l c va a, ObservableContainer c va, IsObservableCore l c vb b, ObservableContainer c vb) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v) => IsObservableCore canLoad c v (LiftA2Observable canLoad c v) where
  readObservable# (LiftA2Observable fn fx fy) =
    liftA2 (liftA2 fn) (readObservable# fx) (readObservable# fy)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: forall canLoad c v ca va cb vb a b.
  (IsObservableCore canLoad ca va a, IsObservableCore canLoad cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad c v)
attachEvaluatedMergeObserver mergeState =
  attachCoreMergeObserver mergeState fn fn2 clearFn clearFn
  where
    fn :: Delta ca va -> ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    fn _delta _x _prev NothingL = Just MergeChangeClear
    fn _ x _prev (JustL y) = Just (MergeChangeDelta (toInitialDelta (mergeState x y)))
    fn2 :: Delta cb vb -> cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    fn2 _y _delta _x NothingL = Just MergeChangeClear
    fn2 _ y _prev (JustL x) = Just (MergeChangeDelta (toInitialDelta (mergeState x y)))
    clearFn :: forall d e. canLoad :~: Load -> d -> e -> Maybe (MergeChange canLoad c v)
    clearFn Refl _ _ = Just MergeChangeClear


data MergeChange canLoad c v where
  MergeChangeClear :: MergeChange Load c v
  MergeChangeDelta :: Delta c v -> MergeChange canLoad c v

instance ObservableContainer c v => Semigroup (MergeChange canLoad c v) where
  _ <> MergeChangeClear = MergeChangeClear
  MergeChangeClear <> y = y
  MergeChangeDelta x <> MergeChangeDelta y = MergeChangeDelta (mergeDelta @c x y)


attachCoreMergeObserver
  :: forall canLoad ca va cb vb c v a b.
  (IsObservableCore canLoad ca va a, IsObservableCore canLoad cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta ca va -> ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta cb vb -> cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v))
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
  -> (ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad c v)
attachCoreMergeObserver fullMergeFn leftFn rightFn clearLeftFn clearRightFn fx fy callback = do
  mfixTVar \leftState -> mfixTVar \rightState -> mfixTVar \state -> do
    (disposerX, stateX) <- attachEvaluatedObserver# fx (mergeCallback @canLoad @c leftState rightState state fullMergeFn leftFn clearLeftFn callback)
    (disposerY, stateY) <- attachEvaluatedObserver# fy (mergeCallback @canLoad @c rightState leftState state (flip fullMergeFn) rightFn clearRightFn callback)
    let
      initialState = mergeObservableState fullMergeFn stateX stateY
      initialMergeState = (emptyPendingChange initialState.loading, initialLastChange initialState.loading)
      initialLeftState = createObserverState stateX
      initialRightState = createObserverState stateY
    pure ((((disposerX <> disposerY, initialState), initialLeftState), initialRightState), initialMergeState)

mergeCallback
  :: forall canLoad c v ca va cb vb. ObservableContainer c v
  => TVar (ObserverState canLoad ca va)
  -> TVar (ObserverState canLoad cb vb)
  -> TVar (PendingChange canLoad c v, LastChange canLoad c v)
  -> (ca va -> cb vb -> c v)
  -> (Delta ca va -> ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
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
          EvaluatedObservableChangeLiveDelta delta evaluated ->
            mapM_ (applyMergeChange otherState.loading) (fn delta evaluated oldState.maybe otherState.maybeL)
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


attachMergeObserver
  :: forall canLoad exceptions ca va cb vb c v a b.
  (
    IsObservableCore canLoad (ObservableResult exceptions ca) va a,
    IsObservableCore canLoad (ObservableResult exceptions cb) vb b,
    ObservableContainer ca va,
    ObservableContainer cb vb,
    ObservableContainer c v
  )
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (Delta cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v))
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
  attachCoreMergeObserver wrappedFullMergeFn wrappedLeftFn wrappedRightFn wrappedClearLeftFn wrappedClearRightFn fx fy callback
  where
    wrappedFullMergeFn :: ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> ObservableResult exceptions c v
    wrappedFullMergeFn = mergeObservableResult fullMergeFn

    wrappedLeftFn :: Delta (ObservableResult exceptions ca) va -> ObservableResult exceptions ca va -> Maybe (ObservableResult exceptions ca va) -> MaybeL canLoad (ObservableResult exceptions cb vb) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception
    wrappedLeftFn (ObservableResultDeltaThrow ex) _ _ _ = Just (MergeChangeDelta (ObservableResultDeltaThrow ex))

    -- RHS exception
    wrappedLeftFn (ObservableResultDeltaOk _delta) _ _ (JustL (ObservableResultEx _ex)) = Nothing

    wrappedLeftFn (ObservableResultDeltaOk delta) _ (Just (ObservableResultOk prevX)) (JustL (ObservableResultOk y)) = wrapMergeChange <$> leftFn delta (Just prevX) (JustL y)
    wrappedLeftFn (ObservableResultDeltaOk delta) _ (Just (ObservableResultOk prevX)) NothingL = wrapMergeChange <$> leftFn delta (Just prevX) NothingL
    wrappedLeftFn (ObservableResultDeltaOk delta) _ _ (JustL (ObservableResultOk y)) = wrapMergeChange <$> leftFn delta Nothing (JustL y)
    wrappedLeftFn (ObservableResultDeltaOk delta) _ _ NothingL = wrapMergeChange <$> leftFn delta Nothing NothingL

    wrappedRightFn :: Delta (ObservableResult exceptions cb) vb -> ObservableResult exceptions cb vb -> Maybe (ObservableResult exceptions cb vb) -> MaybeL canLoad (ObservableResult exceptions ca va) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception has priority over any RHS change
    wrappedRightFn _ _ _ (JustL (ObservableResultEx _)) = Nothing

    -- Otherwise RHS exception is chosen
    wrappedRightFn (ObservableResultDeltaThrow ex) _ _ _ = Just (MergeChangeDelta (ObservableResultDeltaThrow ex))

    wrappedRightFn (ObservableResultDeltaOk delta) _ (Just (ObservableResultOk prevY)) (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn delta (Just prevY) (JustL x)
    wrappedRightFn (ObservableResultDeltaOk delta) _ (Just (ObservableResultOk prevY)) NothingL = wrapMergeChange <$> rightFn delta (Just prevY) NothingL

    wrappedRightFn (ObservableResultDeltaOk delta) _ _ (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn delta Nothing (JustL x)
    wrappedRightFn (ObservableResultDeltaOk delta) _ _ NothingL = wrapMergeChange <$> rightFn delta Nothing NothingL

    wrappedClearLeftFn :: canLoad :~: Load -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearLeftFn Refl (ObservableResultOk prevX) (ObservableResultOk y) = wrapMergeChange <$> clearLeftFn Refl prevX y
    wrappedClearLeftFn Refl _ _ = Just MergeChangeClear

    wrappedClearRightFn :: canLoad :~: Load -> ObservableResult exceptions cb vb -> ObservableResult exceptions ca va -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearRightFn Refl (ObservableResultOk prevY) (ObservableResultOk x) = wrapMergeChange <$> clearRightFn Refl prevY x
    wrappedClearRightFn Refl _ _ = Just MergeChangeClear

    wrapMergeChange :: MergeChange canLoad c v -> MergeChange canLoad (ObservableResult exceptions c) v
    wrapMergeChange MergeChangeClear = MergeChangeClear
    wrapMergeChange (MergeChangeDelta delta) = MergeChangeDelta (ObservableResultDeltaOk delta)


attachMonoidMergeObserver
  :: forall canLoad exceptions c v ca va cb vb a b.
  (
    Monoid (ca va),
    Monoid (cb vb),
    IsObservableCore canLoad (ObservableResult exceptions ca) va a,
    IsObservableCore canLoad (ObservableResult exceptions cb) vb b,
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

    wrappedLeftFn :: Delta ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    wrappedLeftFn delta x y = MergeChangeDelta <$> leftFn delta (fromMaybe mempty x) (fromMaybeL mempty y)

    wrappedRightFn :: Delta cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    wrappedRightFn delta y x = MergeChangeDelta <$> rightFn delta (fromMaybe mempty y) (fromMaybeL mempty x)

    clearLeftFn :: canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v)
    clearLeftFn _ prev other = wrappedLeftFn (toInitialDelta @ca mempty) (Just prev) (JustL other)

    clearRightFn :: canLoad :~: Load -> cb vb -> ca va -> Maybe (MergeChange canLoad c v)
    clearRightFn _ prev other = wrappedRightFn (toInitialDelta @cb mempty) (Just prev) (JustL other)



data EvaluatedBindObservable canLoad c v = forall d p a. (IsObservableCore canLoad d p a, ObservableContainer d p) => EvaluatedBindObservable a (d p -> ObservableCore canLoad c v)

data BindState canLoad c v where
  -- LHS cleared
  BindStateCleared :: BindState Load c v
  -- RHS attached
  BindStateAttachedLoading :: TSimpleDisposer -> BindRHS canLoad c v -> BindState canLoad c v
  BindStateAttachedLive :: TSimpleDisposer -> BindRHS canLoad c v -> BindState canLoad c v

data BindRHS canLoad c v where
  BindRHSCleared :: BindRHS Load c v
  BindRHSPendingDelta :: Loading canLoad -> Delta c v -> BindRHS canLoad c v
  -- Downstream observer has valid content
  BindRHSValid :: Loading canLoad -> BindRHS canLoad c v

reactivateBindRHS :: BindRHS canLoad c v -> Maybe (ObservableChange canLoad c v, BindRHS canLoad c v)
reactivateBindRHS (BindRHSPendingDelta Live delta) = Just (ObservableChangeLiveDelta delta, BindRHSValid Live)
reactivateBindRHS (BindRHSValid Live) = Just (ObservableChangeLiveUnchanged, BindRHSValid Live)
reactivateBindRHS _ = Nothing

bindRHSSetLoading :: Loading canLoad -> BindRHS canLoad c v -> BindRHS canLoad c v
bindRHSSetLoading _loading BindRHSCleared = BindRHSCleared
bindRHSSetLoading loading (BindRHSPendingDelta _ delta) = BindRHSPendingDelta loading delta
bindRHSSetLoading loading (BindRHSValid _) = BindRHSValid loading

updateSuspendedBindRHS
  :: forall canLoad c v. ObservableContainer c v
  => ObservableChange canLoad c v
  -> BindRHS canLoad c v
  -> BindRHS canLoad c v
updateSuspendedBindRHS ObservableChangeLoadingClear _ = BindRHSCleared
updateSuspendedBindRHS ObservableChangeLoadingUnchanged rhs = bindRHSSetLoading Loading rhs
updateSuspendedBindRHS ObservableChangeLiveUnchanged rhs = bindRHSSetLoading Live rhs
updateSuspendedBindRHS (ObservableChangeLiveDelta delta) (BindRHSPendingDelta _ prevDelta) = BindRHSPendingDelta Live (mergeDelta @c prevDelta delta)
updateSuspendedBindRHS (ObservableChangeLiveDelta delta) _ = BindRHSPendingDelta Live delta

updateActiveBindRHS
  :: forall canLoad c v. ObservableContainer c v
  => ObservableChange canLoad c v
  -> BindRHS canLoad c v
  -> (ObservableChange canLoad c v, BindRHS canLoad c v)
updateActiveBindRHS ObservableChangeLoadingClear _ = (ObservableChangeLoadingClear, BindRHSCleared)
updateActiveBindRHS ObservableChangeLoadingUnchanged rhs = (ObservableChangeLoadingUnchanged, bindRHSSetLoading Loading rhs)
updateActiveBindRHS ObservableChangeLiveUnchanged (BindRHSPendingDelta _ delta) = (ObservableChangeLiveDelta delta, BindRHSValid Live)
updateActiveBindRHS ObservableChangeLiveUnchanged rhs = (ObservableChangeLiveUnchanged, bindRHSSetLoading Live rhs)
updateActiveBindRHS (ObservableChangeLiveDelta delta) (BindRHSPendingDelta _ prevDelta) = (ObservableChangeLiveDelta (mergeDelta @c prevDelta delta), BindRHSValid Live)
updateActiveBindRHS (ObservableChangeLiveDelta delta) _ = (ObservableChangeLiveDelta delta, BindRHSValid Live)


instance ObservableContainer c v => IsObservableCore canLoad c v (EvaluatedBindObservable canLoad c v) where
  readObservable# (EvaluatedBindObservable fx fn) = do
    x <- readObservable# fx
    readObservable# (fn x)

  attachObserver# (EvaluatedBindObservable fx fn) callback = do
    mfixTVar \var -> do
      (disposerX, initialX) <- attachEvaluatedObserver# fx \changeX -> do
        case changeX of
          EvaluatedObservableChangeLoadingClear -> do
            detach var
            writeTVar var BindStateCleared
          EvaluatedObservableChangeLoadingUnchanged -> do
            bindState <- readTVar var
            case bindState of
              BindStateCleared -> pure ()
              BindStateAttachedLive disposer rhs@(BindRHSValid Live) -> do
                writeTVar var (BindStateAttachedLoading disposer rhs)
                callback ObservableChangeLoadingUnchanged
              BindStateAttachedLive disposer rhs -> do
                writeTVar var (BindStateAttachedLoading disposer rhs)
              BindStateAttachedLoading{} -> pure ()
          EvaluatedObservableChangeLiveUnchanged -> do
            bindState <- readTVar var
            case bindState of
              BindStateCleared -> pure ()
              BindStateAttachedLoading disposer rhs -> do
                case reactivateBindRHS rhs of
                  Nothing -> writeTVar var (BindStateAttachedLive disposer rhs)
                  Just (change, newRhs) -> do
                    writeTVar var (BindStateAttachedLive disposer newRhs)
                    callback change
              BindStateAttachedLive{} -> pure ()
          EvaluatedObservableChangeLiveDelta _deltaX evaluatedX -> do
            detach var
            (stateY, bindState) <- attach var (fn evaluatedX)
            writeTVar var bindState
            callback case stateY of
              ObservableStateLoading -> ObservableChangeLoadingClear
              ObservableStateLive evaluatedY ->
                ObservableChangeLiveDelta (toInitialDelta evaluatedY)

      (initial, bindState) <- case initialX of
        ObservableStateLoading -> pure (ObservableStateLoading, BindStateCleared)
        ObservableStateLive x -> attach var (fn x)

      disposer <- newUnmanagedTSimpleDisposer (detach var)

      pure ((disposerX <> disposer, initial), bindState)
    where
      attach
        :: TVar (BindState canLoad c v)
        -> ObservableCore canLoad c v
        -> STMc NoRetry '[] (ObservableState canLoad c v, BindState canLoad c v)
      attach var fy = do
        (disposerY, initialY) <- attachObserver# fy \changeY -> do
          bindState <- readTVar var
          case bindState of
            BindStateAttachedLoading disposer rhs ->
              writeTVar var (BindStateAttachedLoading disposer (updateSuspendedBindRHS changeY rhs))
            BindStateAttachedLive disposer rhs -> do
              let !(change, newRHS) = updateActiveBindRHS changeY rhs
              writeTVar var (BindStateAttachedLive disposer newRHS)
              callback change
            _ -> pure () -- error: no RHS should be attached in this state
        pure (initialY, BindStateAttachedLive disposerY (BindRHSValid (observableStateIsLoading initialY)))

      detach :: TVar (BindState canLoad c v) -> STMc NoRetry '[] ()
      detach var = detach' =<< readTVar var

      detach' :: BindState canLoad c v -> STMc NoRetry '[] ()
      detach' (BindStateAttachedLoading disposer _) = disposeTSimpleDisposer disposer
      detach' (BindStateAttachedLive disposer _) = disposeTSimpleDisposer disposer
      detach' _ = pure ()

  count# (EvaluatedBindObservable fx fn) = evaluateObservableCore fx >>= count# . fn
  isEmpty# (EvaluatedBindObservable fx fn) = evaluateObservableCore fx >>= isEmpty# . fn
bindObservable
  :: forall canLoad exceptions c v a. ObservableContainer c v
  => Observable canLoad exceptions Identity a
  -> (a -> Observable canLoad exceptions c v)
  -> Observable canLoad exceptions c v
bindObservable (Observable fx) fn = Observable (ObservableCore (EvaluatedBindObservable fx rhsHandler))
  where
    rhsHandler :: ObservableResult exceptions Identity a -> ObservableCore canLoad (ObservableResult exceptions c) v
    rhsHandler (ObservableResultOk (Identity (fn -> Observable x))) = x
    rhsHandler (ObservableResultEx ex) = constObservableCore (ObservableStateLiveEx ex)


-- ** Observable Identity

type ObservableI :: CanLoad -> [Type] -> Type -> Type
type ObservableI canLoad exceptions a = Observable canLoad exceptions Identity a
type ToObservableI :: CanLoad -> [Type] -> Type -> Type -> Constraint
type ToObservableI canLoad exceptions a = ToObservable canLoad exceptions Identity a

instance Applicative (Observable canLoad exceptions Identity) where
  pure x = constObservable (pure x)
  liftA2 f (Observable x) (Observable y) = Observable (ObservableCore (LiftA2Observable f x y))

instance Monad (Observable canLoad exceptions Identity) where
  (>>=) = bindObservable

toObservableI :: ToObservableI canLoad exceptions v a => a -> ObservableI canLoad exceptions v
toObservableI = toObservable


-- ** ObservableMap

type ObservableMap canLoad exceptions k v = Observable canLoad exceptions (Map k) v

type ToObservableMap canLoad exceptions k v = ToObservable canLoad exceptions (Map k) v

data ObservableMapDelta k v
  = ObservableMapUpdate (Map k (ObservableMapOperation v))
  | ObservableMapReplace (Map k v)
  deriving Generic

instance (Binary k, Binary v) => Binary (ObservableMapDelta k v)

instance Functor (ObservableMapDelta k) where
  fmap f (ObservableMapUpdate x) = ObservableMapUpdate (f <<$>> x)
  fmap f (ObservableMapReplace x) = ObservableMapReplace (f <$> x)

instance Foldable (ObservableMapDelta k) where
  foldMap f (ObservableMapUpdate x) = foldMap (foldMap f) x
  foldMap f (ObservableMapReplace x) = foldMap f x

instance Traversable (ObservableMapDelta k) where
  traverse f (ObservableMapUpdate ops) = ObservableMapUpdate <$> traverse (traverse f) ops
  traverse f (ObservableMapReplace new) = ObservableMapReplace <$> traverse f new

data ObservableMapOperation v = ObservableMapInsert v | ObservableMapDelete
  deriving Generic

instance Binary v => Binary (ObservableMapOperation v)

instance Functor ObservableMapOperation where
  fmap f (ObservableMapInsert x) = ObservableMapInsert (f x)
  fmap _f ObservableMapDelete = ObservableMapDelete

instance Foldable ObservableMapOperation where
  foldMap f (ObservableMapInsert x) = f x
  foldMap _f ObservableMapDelete = mempty

instance Traversable ObservableMapOperation where
  traverse f (ObservableMapInsert x) = ObservableMapInsert <$> f x
  traverse _f ObservableMapDelete = pure ObservableMapDelete

observableMapOperationToMaybe :: ObservableMapOperation v -> Maybe v
observableMapOperationToMaybe (ObservableMapInsert x) = Just x
observableMapOperationToMaybe ObservableMapDelete = Nothing

applyObservableMapOperations :: Ord k => Map k (ObservableMapOperation v) -> Map k v -> Map k v
applyObservableMapOperations ops old =
  Map.merge
    Map.preserveMissing'
    (Map.mapMaybeMissing \_ -> observableMapOperationToMaybe)
    (Map.zipWithMaybeMatched \_ _ -> observableMapOperationToMaybe)
    old
    ops

instance Ord k => ObservableContainer (Map k) v where
  type Delta (Map k) = (ObservableMapDelta k)
  type Key (Map k) v = k
  type ContainerExceptions (Map k) = '[]
  applyDelta (ObservableMapReplace new) _ = new
  applyDelta (ObservableMapUpdate ops) old = applyObservableMapOperations ops old
  mergeDelta _ new@ObservableMapReplace{} = new
  mergeDelta (ObservableMapUpdate old) (ObservableMapUpdate new) = ObservableMapUpdate (Map.union new old)
  mergeDelta (ObservableMapReplace old) (ObservableMapUpdate new) = ObservableMapReplace (applyObservableMapOperations new old)
  toInitialDelta = ObservableMapReplace
  initializeFromDelta (ObservableMapReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta (ObservableMapUpdate _) = error "ObservableMap.initializeFromDelta: expected ObservableMapReplace"
  containerCount# x = pure (fromIntegral (Map.size x))
  containerIsEmpty# x = pure (Map.null x)

toObservableMap :: ToObservable canLoad exceptions (Map k) v a => a -> ObservableMap canLoad exceptions k v
toObservableMap = toObservable


-- ** ObservableSet

type ObservableSet canLoad exceptions v = Observable canLoad exceptions Set v

type ToObservableSet canLoad exceptions v = ToObservable canLoad exceptions Set v

data ObservableSetDelta v
  = ObservableSetUpdate (Set (ObservableSetOperation v))
  | ObservableSetReplace (Set v)

data ObservableSetOperation v = ObservableSetInsert v | ObservableSetDelete v
  deriving (Eq, Ord)

applyObservableSetOperation :: Ord v => ObservableSetOperation v -> Set v -> Set v
applyObservableSetOperation (ObservableSetInsert x) = Set.insert x
applyObservableSetOperation (ObservableSetDelete x) = Set.delete x

applyObservableSetOperations :: Ord v => Set (ObservableSetOperation v) -> Set v -> Set v
applyObservableSetOperations ops old = Set.foldr applyObservableSetOperation old ops

instance Ord v => ObservableContainer Set v where
  type Delta Set = ObservableSetDelta
  type Key Set v = v
  type ContainerExceptions Set = '[]
  applyDelta (ObservableSetReplace new) _ = new
  applyDelta (ObservableSetUpdate ops) old = applyObservableSetOperations ops old
  mergeDelta _ new@ObservableSetReplace{} = new
  mergeDelta (ObservableSetUpdate old) (ObservableSetUpdate new) = ObservableSetUpdate (Set.union new old)
  mergeDelta (ObservableSetReplace old) (ObservableSetUpdate new) = ObservableSetReplace (applyObservableSetOperations new old)
  toInitialDelta = ObservableSetReplace
  initializeFromDelta (ObservableSetReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta _ = error "ObservableSet.initializeFromDelta: expected ObservableSetReplace"
  containerCount# x = pure (fromIntegral (Set.size x))
  containerIsEmpty# x = pure (Set.null x)

toObservableSet :: ToObservable canLoad exceptions Set v a => a -> ObservableSet canLoad exceptions v
toObservableSet = toObservable


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

unwrapObservableResult :: MonadSTMc NoRetry exceptions m => ObservableResult exceptions c v -> m (c v)
unwrapObservableResult (ObservableResultOk result) = pure result
unwrapObservableResult (ObservableResultEx ex) = throwEx ex

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
  type Delta (ObservableResult exceptions c) = ObservableResultDelta exceptions c
  type Key (ObservableResult exceptions c) v = Key c v
  type ContainerExceptions (ObservableResult exceptions c) = exceptions
  applyDelta (ObservableResultDeltaThrow ex) _ = ObservableResultEx ex
  applyDelta (ObservableResultDeltaOk delta) (ObservableResultOk old) = ObservableResultOk (applyDelta delta old)
  applyDelta (ObservableResultDeltaOk delta) _ = ObservableResultOk (initializeFromDelta delta)
  mergeDelta (ObservableResultDeltaOk old) (ObservableResultDeltaOk new) = ObservableResultDeltaOk (mergeDelta @c old new)
  mergeDelta _ new = new
  toInitialDelta (ObservableResultOk initial) = ObservableResultDeltaOk (toInitialDelta initial)
  toInitialDelta (ObservableResultEx ex) = ObservableResultDeltaThrow ex
  initializeFromDelta (ObservableResultDeltaOk initial) = ObservableResultOk (initializeFromDelta initial)
  initializeFromDelta (ObservableResultDeltaThrow ex) = ObservableResultEx ex
  containerCount# (ObservableResultOk x) = error "TODO relax ex" -- containerCount# x
  containerCount# (ObservableResultEx ex) = error "TODO throwEx support" -- throwEx ex
  containerIsEmpty# (ObservableResultOk x) = error "TODO relax ex" -- containerIsEmpty# x
  containerIsEmpty# (ObservableResultEx ex) = error "TODO throwEx support" -- throwEx ex

-- *** Wrap container in ObservableResultOk

newtype AlwaysOk canLoad exceptions c v = AlwaysOk (ObservableCore canLoad c v)

instance ObservableContainer c v => IsObservableCore canLoad (ObservableResult exceptions c) v (AlwaysOk canLoad exceptions c v) where
  readObservable# (AlwaysOk x) = ObservableResultOk <$> readObservable# x
  attachObserver# (AlwaysOk x) callback = mapObservableState ObservableResultOk <<$>> attachObserver# x wrappedCallback
    where
      wrappedCallback change = callback (mapObservableChangeDelta ObservableResultDeltaOk change)
  attachEvaluatedObserver# (AlwaysOk x) callback = mapObservableState ObservableResultOk <<$>> attachEvaluatedObserver# x (callback . wrapChange)
    where
      wrapChange :: EvaluatedObservableChange canLoad c v -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v
      wrapChange EvaluatedObservableChangeLoadingClear = EvaluatedObservableChangeLoadingClear
      wrapChange EvaluatedObservableChangeLoadingUnchanged = EvaluatedObservableChangeLoadingUnchanged
      wrapChange EvaluatedObservableChangeLiveUnchanged = EvaluatedObservableChangeLiveUnchanged
      wrapChange (EvaluatedObservableChangeLiveDelta delta evaluated) =
        EvaluatedObservableChangeLiveDelta (ObservableResultDeltaOk delta) (ObservableResultOk evaluated)

observableFromCore :: forall canLoad exceptions c v. ObservableContainer c v => ObservableCore canLoad c v -> Observable canLoad exceptions c v
observableFromCore x = Observable (ObservableCore (AlwaysOk @canLoad @exceptions x))
