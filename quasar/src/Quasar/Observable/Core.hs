{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
  Observable(ConstObservable, DynObservable, Observable),
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
  Final,
  ObservableChange(..),
  EvaluatedObservableChange(..),
  ObservableState(.., ObservableStateLiveOk, ObservableStateLiveEx),
  ObserverState(.., ObserverStateLoading, ObserverStateLiveOk, ObserverStateLiveEx),
  createObserverState,
  toObservableState,
  applyObservableChange,
  applyEvaluatedObservableChange,

  -- *** Exception handling types
  ObservableResult(..),
  ObservableResultDelta(..),
  unwrapObservableResult,
  mapObservableResultContent,

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
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Map.Merge.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (IsString(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type ToObservable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c v => ToObservable canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  toObservable :: a -> Observable canLoad exceptions c v

type IsObservableCore :: CanLoad -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c v => IsObservableCore canLoad c v a | a -> canLoad, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable#
    :: canLoad ~ NoLoad
    => a
    -> STMc NoRetry '[] (Final, c v)

  attachObserver#
    :: a
    -> (Final -> ObservableChange canLoad c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad c v)
  attachObserver# x callback = attachEvaluatedObserver# x \final evaluatedChange ->
    callback final case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveDelta delta _ -> ObservableChangeLiveDelta delta

  attachEvaluatedObserver#
    :: a
    -> (Final -> EvaluatedObservableChange canLoad c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad c v)
  attachEvaluatedObserver# x callback =
    mfixTVar \var -> do
      (disposer, final, initial) <- attachObserver# x \final change -> do
        cached <- readTVar var
        forM_ (applyObservableChange change cached) \(evaluatedChange, newCached) -> do
          writeTVar var newCached
          callback final evaluatedChange

      pure ((disposer, final, initial), createObserverState initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: ObservableFunctor c => (v -> n) -> a -> ObservableCore canLoad c n
  mapObservable# f x = DynObservableCore (MappedObservable f x)

  mapObservableContent#
    :: ObservableContainer ca va
    => (c v -> ca va)
    -> a
    -> ObservableCore canLoad ca va
  mapObservableContent# f x = DynObservableCore (MappedStateObservable f x)

  count# :: a -> ObservableCore canLoad (SelectorResult c) Int64
  count# = undefined

  isEmpty# :: a -> ObservableCore canLoad (SelectorResult c) Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c v) => a -> Selector c v -> ObservableCore canLoad (SelectorResult c) (Maybe (Key c v))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c v) => a -> Selector c v -> ObservableCore canLoad (SelectorResult c) (Maybe (Key c v, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key c v) => a -> Selector c v -> ObservableCore canLoad (SelectorResult c) (Maybe v)
  lookupValue# = undefined

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

readObservable
  :: forall exceptions c v m a.
  (ToObservable NoLoad exceptions c v a, MonadSTMc NoRetry exceptions m)
  => a -> m (c v)
readObservable x = liftSTMc @NoRetry @exceptions case toObservable x of
  (ConstObservable (ObservableStateLive (ObservableResultOk result))) -> pure result
  (ConstObservable (ObservableStateLive (ObservableResultEx ex))) -> throwEx ex
  (DynObservable y) -> liftSTMc @NoRetry @'[] (readObservable# y) >>= \case
    (_final, result) -> unwrapObservableResult result

attachObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad (ObservableResult exceptions c) v)
attachObserver x callback = liftSTMc
  case toObservable x of
    DynObservable f -> attachObserver# f callback
    ConstObservable result -> pure (mempty, True, result)

attachEvaluatedObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad (ObservableResult exceptions c) v)
attachEvaluatedObserver x callback = liftSTMc
  case toObservable x of
    DynObservable f -> attachEvaluatedObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToObservable canLoad exceptions c v a => a -> Bool
isCachedObservable x = case toObservable x of
  DynObservable f -> isCachedObservable# f
  ConstObservable _value -> True

mapObservable :: (ObservableFunctor c, ToObservable canLoad exceptions c v a) => (v -> va) -> a -> Observable canLoad exceptions c va
mapObservable fn x = case toObservable x of
  (DynObservable f) -> toObservable (mapObservable# fn f)
  (ConstObservable content) -> ConstObservable (fn <$> content)

mapObservableCore :: ObservableFunctor c => (v -> f) -> ObservableCore canLoad c v -> ObservableCore canLoad c f
mapObservableCore fn (ConstObservableCore content) = ConstObservableCore (fn <$> content)
mapObservableCore fn (DynObservableCore f) = mapObservable# fn f

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanLoad = Load | NoLoad
#else
data CanLoad = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad
#endif


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

{-# COMPLETE ObservableStateLiveOk, ObservableStateLiveEx, ObservableStateLoading #-}

pattern ObservableStateLiveOk :: forall canLoad exceptions c v. c v -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveOk content = ObservableStateLive (ObservableResultOk content)

pattern ObservableStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveEx ex = ObservableStateLive (ObservableResultEx ex)

type ObservableState :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: c v -> ObservableState canLoad c v

mapObservableState :: (cp vp -> c v) -> ObservableState canLoad cp vp -> ObservableState canLoad c v
mapObservableState _fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)

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
pattern ObserverStateLoading <- (observerStateIsLoading -> Loading)

{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoading #-}
{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoadingCached, ObserverStateLoadingCleared #-}

pattern ObserverStateLiveOk :: forall canLoad exceptions c v. c v -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveOk content = ObserverStateLive (ObservableResultOk content)

pattern ObserverStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveEx ex = ObserverStateLive (ObservableResultEx ex)

observerStateIsLoading :: ObserverState canLoad c v -> Loading canLoad
observerStateIsLoading ObserverStateLoadingCleared = Loading
observerStateIsLoading (ObserverStateLoadingCached _) = Loading
observerStateIsLoading (ObserverStateLive _) = Live

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


type ObservableCore :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableCore canLoad c v
  = forall a. IsObservableCore canLoad c v a => DynObservableCore a
  | ConstObservableCore (ObservableState canLoad c v)

instance ObservableContainer c v => ToObservable canLoad exceptions c v (ObservableCore canLoad (ObservableResult exceptions c) v) where
  toObservable = Observable

instance ObservableFunctor c => Functor (ObservableCore canLoad c) where
  fmap = mapObservableCore

instance (IsString v, Applicative c) => IsString (ObservableCore canLoad c v) where
  fromString x = ConstObservableCore (pure (fromString x))


type Observable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
newtype Observable canLoad exceptions c v = Observable (ObservableCore canLoad (ObservableResult exceptions c) v)

{-# COMPLETE ConstObservable, DynObservable #-}

pattern ConstObservable :: ObservableState canLoad (ObservableResult exceptions c) v -> Observable canLoad exceptions c v
pattern ConstObservable x = Observable (ConstObservableCore x)

pattern DynObservable :: () => IsObservableCore canLoad (ObservableResult exceptions c) v a => a -> Observable canLoad exceptions c v
pattern DynObservable x = Observable (DynObservableCore x)

instance ObservableContainer c v => ToObservable canLoad exceptions c v (Observable canLoad exceptions c v) where
  toObservable = id

instance ObservableFunctor c => Functor (Observable canLoad exceptions c) where
  fmap = mapObservable

instance (IsString v, Applicative c) => IsString (Observable canLoad exceptions c v) where
  fromString x = ConstObservable (pure (fromString x))


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type Delta c :: Type -> Type
  type Key c v
  type SelectorResult c :: Type -> Type
  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: Delta c v -> Delta c v -> Delta c v
  -- | Produce a delta from a content. The delta replaces any previous content when
  -- applied.
  toInitialDelta :: c v -> Delta c v
  initializeFromDelta :: Delta c v -> c v

type ObservableFunctor c = (Functor c, Functor (Delta c), forall v. ObservableContainer c v)

instance ObservableContainer Identity v where
  type Delta Identity = Identity
  type Key Identity v = ()
  type SelectorResult Identity = Identity
  applyDelta new _ = new
  mergeDelta _ new = new
  toInitialDelta = id
  initializeFromDelta = id


evaluateObservable :: ToObservable canLoad exceptions c v a => a -> Observable canLoad exceptions Identity (c v)
evaluateObservable x = mapObservableContent Identity x


data MappedObservable canLoad c v = forall prev a. IsObservableCore canLoad c prev a => MappedObservable (prev -> v) a

instance ObservableFunctor c => IsObservableCore canLoad c v (MappedObservable canLoad c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    DynObservableCore $ MappedObservable (f1 . f2) upstream


data MappedStateObservable canLoad c v = forall d p a. IsObservableCore canLoad d p a => MappedStateObservable (d p -> c v) a

instance ObservableContainer c v => IsObservableCore canLoad c v (MappedStateObservable canLoad c v) where
  attachEvaluatedObserver# (MappedStateObservable fn observable) callback =
    fmap2 (mapObservableState fn) $ attachEvaluatedObserver# observable \final evaluatedChange ->
      callback final case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoadingUnchanged -> EvaluatedObservableChangeLoadingUnchanged
        EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
        EvaluatedObservableChangeLiveDelta _delta evaluated ->
          let new = fn evaluated
          in EvaluatedObservableChangeLiveDelta (toInitialDelta new) new

  readObservable# (MappedStateObservable fn observable) =
    fn <<$>> readObservable# observable

  mapObservable# f1 (MappedStateObservable f2 observable) =
    DynObservableCore (MappedStateObservable (fmap f1 . f2) observable)

  mapObservableContent# f1 (MappedStateObservable f2 observable) =
    DynObservableCore (MappedStateObservable (f1 . f2) observable)

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapObservableContent :: (ToObservable canLoad exceptions d p a, ObservableContainer c v) => (d p -> c v) -> a -> Observable canLoad exceptions c v
mapObservableContent fn x = case toObservable x of
  (ConstObservable wstate) -> ConstObservable (mapObservableResultState fn wstate)
  (DynObservable f) -> toObservable (mapObservableContent# (mapObservableResultContent fn) f)

mapObservableResultState :: (cp vp -> c v) -> ObservableState canLoad (ObservableResult exceptions cp) vp -> ObservableState canLoad (ObservableResult exceptions c) v
mapObservableResultState _fn ObservableStateLoading = ObservableStateLoading
mapObservableResultState _fn (ObservableStateLiveEx ex) = ObservableStateLiveEx ex
mapObservableResultState fn (ObservableStateLiveOk content) = ObservableStateLiveOk (fn content)


data LiftA2Observable l c v = forall va vb a b. (IsObservableCore l c va a, IsObservableCore l c vb b) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v) => IsObservableCore canLoad c v (LiftA2Observable canLoad c v) where
  readObservable# (LiftA2Observable fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, liftA2 fn x y)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: (IsObservableCore canLoad ca va a, IsObservableCore canLoad cb vb b, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (Final -> ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad c v)
attachEvaluatedMergeObserver mergeState =
  attachMergeObserver mergeState (fn mergeState) (fn (flip mergeState))
  where
    fn :: ObservableContainer c v => (ca va -> cb vb -> c v) -> Delta ca va -> ca va -> cb vb -> Maybe (Delta c v)
    fn mergeState' _ x y = Just $ toInitialDelta $ mergeState' x y

data MergeState canLoad where
  MergeStateLoadingCleared :: MergeState Load
  MergeStateValid :: Loading canLoad -> MergeState canLoad

{-# COMPLETE MergeStateLoading, MergeStateLive #-}

pattern MergeStateLoading :: () => (canLoad ~ Load) => MergeState canLoad
pattern MergeStateLoading <- (mergeStateIsLoading -> Loading)

pattern MergeStateLive :: MergeState canLoad
pattern MergeStateLive <- (mergeStateIsLoading -> Live)

mergeStateIsLoading :: MergeState canLoad -> Loading canLoad
mergeStateIsLoading MergeStateLoadingCleared = Loading
mergeStateIsLoading (MergeStateValid loading) = loading

changeMergeState :: Loading canLoad -> MergeState canLoad -> MergeState canLoad
changeMergeState _loading MergeStateLoadingCleared = MergeStateLoadingCleared
changeMergeState loading (MergeStateValid _) = MergeStateValid loading

attachMergeObserver
  :: forall canLoad ca va cb vb c v a b.
  (IsObservableCore canLoad ca va a, IsObservableCore canLoad cb vb b, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> (Delta ca va -> ca va -> cb vb -> Maybe (Delta c v))
  -> (Delta cb vb -> cb vb -> ca va -> Maybe (Delta c v))
  -> a
  -> b
  -> (Final -> ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad c v)
attachMergeObserver mergeFn applyDeltaLeft applyDeltaRight fx fy callback = do
  mfixTVar \var -> do
    (disposerX, initialFinalX, initialX) <- attachEvaluatedObserver# fx \finalX evaluatedChangeX -> do
      (_, oldStateX, finalY, stateY, oldMerged) <- readTVar var
      let
        final = finalX && finalY
        mresult = do
          stateX <- applyEvaluatedObservableChange evaluatedChangeX oldStateX
          (change, merged) <- mergeLeft evaluatedChangeX stateX stateY oldMerged
          pure (stateX, change, merged)
      case mresult of
        Nothing -> do
          when final do
            callback final case mergeStateIsLoading oldMerged of
              Loading -> ObservableChangeLoadingClear
              Live -> ObservableChangeLiveUnchanged
        Just (stateX, change, merged) -> do
          writeTVar var (finalX, stateX, finalY, stateY, merged)
          callback final change

    (disposerY, initialFinalY, initialY) <- attachEvaluatedObserver# fy \finalY evaluatedChangeY -> do
      (finalX, stateX, _, oldStateY, oldMerged) <- readTVar var
      let
        final = finalX && finalY
        mresult = do
          stateY <- applyEvaluatedObservableChange evaluatedChangeY oldStateY
          (change, merged) <- mergeRight evaluatedChangeY stateX stateY oldMerged
          pure (stateY, change, merged)
      case mresult of
        Nothing -> do
          when final do
            callback final case mergeStateIsLoading oldMerged of
              Loading -> ObservableChangeLoadingClear
              Live -> ObservableChangeLiveUnchanged
        Just (stateY, change, merged) -> do
          writeTVar var (finalX, stateX, finalY, stateY, merged)
          callback final change

    let
      disposer = disposerX <> disposerY
      final = initialFinalX && initialFinalY
      (initialState, initialMergeState) = case (initialX, initialY) of
        (ObservableStateLive x, ObservableStateLive y) -> (ObservableStateLive (mergeFn x y), MergeStateValid Live)
        (ObservableStateLoading, _) -> (ObservableStateLoading, MergeStateLoadingCleared)
        (_, ObservableStateLoading) -> (ObservableStateLoading, MergeStateLoadingCleared)
    pure ((disposer, final, initialState), (initialFinalX, createObserverState initialX, initialFinalY, createObserverState initialY, initialMergeState))
  where
    mergeLeft
      :: EvaluatedObservableChange canLoad ca va
      -> ObserverState canLoad ca va
      -> ObserverState canLoad cb vb
      -> MergeState canLoad
      -> Maybe (ObservableChange canLoad c v, MergeState canLoad)
    mergeLeft EvaluatedObservableChangeLoadingClear _ _ MergeStateLoadingCleared = Nothing
    mergeLeft EvaluatedObservableChangeLoadingClear _ _ _ = Just (ObservableChangeLoadingClear, MergeStateLoadingCleared)

    mergeLeft EvaluatedObservableChangeLoadingUnchanged _ _ MergeStateLoading = Nothing
    mergeLeft EvaluatedObservableChangeLoadingUnchanged _ _ merged = Just (ObservableChangeLoadingUnchanged, changeMergeState Loading merged)

    mergeLeft EvaluatedObservableChangeLiveUnchanged _ _ MergeStateLive = Nothing
    mergeLeft EvaluatedObservableChangeLiveUnchanged _ ObserverStateLoading _ = Nothing
    mergeLeft EvaluatedObservableChangeLiveUnchanged _ _ merged = Just (ObservableChangeLiveUnchanged, changeMergeState Live merged)

    mergeLeft (EvaluatedObservableChangeLiveDelta _ _) _ ObserverStateLoading _ = Nothing
    mergeLeft (EvaluatedObservableChangeLiveDelta delta x) _ (ObserverStateLive y) (MergeStateValid _) = do
      mergedDelta <- applyDeltaLeft delta x y
      pure (ObservableChangeLiveDelta mergedDelta, MergeStateValid Live)
    mergeLeft (EvaluatedObservableChangeLiveDelta _delta x) _ (ObserverStateLive y) _ =
      Just (ObservableChangeLiveDelta (toInitialDelta (mergeFn x y)), MergeStateValid Live)

    mergeRight
      :: EvaluatedObservableChange canLoad cb vb
      -> ObserverState canLoad ca va
      -> ObserverState canLoad cb vb
      -> MergeState canLoad
      -> Maybe (ObservableChange canLoad c v, MergeState canLoad)
    mergeRight EvaluatedObservableChangeLoadingClear _ _ MergeStateLoadingCleared = Nothing
    mergeRight EvaluatedObservableChangeLoadingClear _ _ _ = Just (ObservableChangeLoadingClear, MergeStateLoadingCleared)

    mergeRight EvaluatedObservableChangeLoadingUnchanged _ _ MergeStateLoading = Nothing
    mergeRight EvaluatedObservableChangeLoadingUnchanged _ _ merged = Just (ObservableChangeLoadingUnchanged, changeMergeState Loading merged)

    mergeRight _changeLive ObserverStateLoading _ _ = Nothing

    mergeRight EvaluatedObservableChangeLiveUnchanged _ _ MergeStateLive = Nothing
    mergeRight EvaluatedObservableChangeLiveUnchanged _ _ merged = Just (ObservableChangeLiveUnchanged, changeMergeState Live merged)

    mergeRight (EvaluatedObservableChangeLiveDelta delta y) (ObserverStateLive x) _ (MergeStateValid _) = do
      mergedDelta <- applyDeltaRight delta y x
      pure (ObservableChangeLiveDelta mergedDelta, MergeStateValid Live)
    mergeRight (EvaluatedObservableChangeLiveDelta _delta y) (ObserverStateLive x) _ _ =
      Just (ObservableChangeLiveDelta (toInitialDelta (mergeFn x y)), MergeStateValid Live)


data EvaluatedBindObservable canLoad c v = forall d p a. IsObservableCore canLoad d p a => EvaluatedBindObservable a (d p -> ObservableCore canLoad c v)

data BindState canLoad c v where
  -- LHS cleared
  BindStateCleared :: BindState Load c v
  -- RHS attached
  BindStateAttachedLoading :: TSimpleDisposer -> Final -> BindRHS canLoad c v -> BindState canLoad c v
  BindStateAttachedLive :: TSimpleDisposer -> Final -> BindRHS canLoad c v -> BindState canLoad c v

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
    (finalX, x) <- readObservable# fx
    case fn x of
      ConstObservableCore (ObservableStateLive wy) -> pure (finalX, wy)
      DynObservableCore fy -> do
        (finalY, wy) <- readObservable# fy
        pure (finalX && finalY, wy)

  attachObserver# (EvaluatedBindObservable fx fn) callback = do
    mfixTVar \var -> do
      (disposerX, initialFinalX, initialX) <- attachEvaluatedObserver# fx \finalX changeX -> do
        case changeX of
          EvaluatedObservableChangeLoadingClear -> do
            detach var
            writeTVar var (finalX, BindStateCleared)
          EvaluatedObservableChangeLoadingUnchanged -> do
            (_, bindState) <- readTVar var
            case bindState of
              BindStateCleared -> pure ()
              BindStateAttachedLive disposer finalY rhs@(BindRHSValid Live) -> do
                writeTVar var (finalX, BindStateAttachedLoading disposer finalY rhs)
                callback finalX ObservableChangeLoadingUnchanged
              BindStateAttachedLive disposer finalY rhs -> do
                writeTVar var (finalX, BindStateAttachedLoading disposer finalY rhs)
              BindStateAttachedLoading{} -> pure ()
          EvaluatedObservableChangeLiveUnchanged -> do
            (_, bindState) <- readTVar var
            case bindState of
              BindStateCleared -> pure ()
              BindStateAttachedLoading disposer finalY rhs -> do
                case reactivateBindRHS rhs of
                  Nothing -> writeTVar var (finalX, BindStateAttachedLive disposer finalY rhs)
                  Just (change, newRhs) -> do
                    writeTVar var (finalX, BindStateAttachedLive disposer finalY newRhs)
                    callback (finalX && finalY) change
              BindStateAttachedLive{} -> pure ()
          EvaluatedObservableChangeLiveDelta _deltaX evaluatedX -> do
            detach var
            (finalY, stateY, bindState) <- attach var (fn evaluatedX)
            writeTVar var (finalX, bindState)
            callback (finalX && finalY) case stateY of
              ObservableStateLoading -> ObservableChangeLoadingClear
              ObservableStateLive evaluatedY ->
                ObservableChangeLiveDelta (toInitialDelta evaluatedY)

      (initialFinalY, initial, bindState) <- case initialX of
        ObservableStateLoading -> pure (initialFinalX, ObservableStateLoading, BindStateCleared)
        ObservableStateLive x -> attach var (fn x)

      -- TODO should be disposed when sending final callback
      disposer <- newUnmanagedTSimpleDisposer (detach var)

      pure ((disposerX <> disposer, initialFinalX && initialFinalY, initial), (initialFinalX, bindState))
    where
      attach
        :: TVar (Final, BindState canLoad c v)
        -> ObservableCore canLoad c v
        -> STMc NoRetry '[] (Final, ObservableState canLoad c v, BindState canLoad c v)
      attach var y = do
        case y of
          ConstObservableCore stateY -> pure (True, stateY, BindStateAttachedLive mempty True (BindRHSValid (observableStateIsLoading stateY)))
          DynObservableCore  fy -> do
            (disposerY, initialFinalY, initialY) <- attachObserver# fy \finalY changeY -> do
              (finalX, bindState) <- readTVar var
              case bindState of
                BindStateAttachedLoading disposer _ rhs ->
                  writeTVar var (finalX, BindStateAttachedLoading disposer finalY (updateSuspendedBindRHS changeY rhs))
                BindStateAttachedLive disposer _ rhs -> do
                  let !(change, newRHS) = updateActiveBindRHS changeY rhs
                  writeTVar var (finalX, BindStateAttachedLive disposer finalY newRHS)
                  callback (finalX && finalY) change
                _ -> pure () -- error: no RHS should be attached in this state
            pure (initialFinalY, initialY, BindStateAttachedLive disposerY initialFinalY (BindRHSValid (observableStateIsLoading initialY)))

      detach :: TVar (Final, BindState canLoad c v) -> STMc NoRetry '[] ()
      detach var = detach' . snd =<< readTVar var

      detach' :: BindState canLoad c v -> STMc NoRetry '[] ()
      detach' (BindStateAttachedLoading disposer _ _) = disposeTSimpleDisposer disposer
      detach' (BindStateAttachedLive disposer _ _) = disposeTSimpleDisposer disposer
      detach' _ = pure ()

bindObservable
  :: forall canLoad exceptions c v a. ObservableContainer c v
  => Observable canLoad exceptions Identity a
  -> (a -> Observable canLoad exceptions c v)
  -> Observable canLoad exceptions c v
bindObservable (ConstObservable ObservableStateLoading) _fn =
  ConstObservable ObservableStateLoading
bindObservable (ConstObservable (ObservableStateLiveOk (Identity x))) fn = fn x
bindObservable (ConstObservable (ObservableStateLiveEx ex)) _fn = ConstObservable (ObservableStateLiveEx ex)
bindObservable (DynObservable fx) fn = DynObservable (EvaluatedBindObservable fx rhsHandler)
  where
    rhsHandler :: ObservableResult exceptions Identity a -> ObservableCore canLoad (ObservableResult exceptions c) v
    rhsHandler (ObservableResultOk (Identity (fn -> Observable x))) = x
    rhsHandler (ObservableResultEx ex) = ConstObservableCore (ObservableStateLiveEx ex)


-- ** Observable Identity

type ObservableI :: CanLoad -> [Type] -> Type -> Type
type ObservableI canLoad exceptions a = Observable canLoad exceptions Identity a
type ToObservableI :: CanLoad -> [Type] -> Type -> Type -> Constraint
type ToObservableI canLoad exceptions a = ToObservable canLoad exceptions Identity a

instance Applicative (Observable canLoad exceptions Identity) where
  pure x = ConstObservable (pure x)
  liftA2 f (DynObservable x) (DynObservable y) = DynObservable (LiftA2Observable f x y)
  liftA2 _f (ConstObservable ObservableStateLoading) _ = ConstObservable ObservableStateLoading
  liftA2 _f (ConstObservable (ObservableStateLiveEx ex)) _ = ConstObservable (ObservableStateLiveEx ex)
  liftA2 f (ConstObservable (ObservableStateLiveOk x)) y = mapObservableContent (liftA2 f x) y
  liftA2 _ _ (ConstObservable ObservableStateLoading) = ConstObservable ObservableStateLoading
  liftA2 _ _ (ConstObservable (ObservableStateLiveEx ex)) = ConstObservable (ObservableStateLiveEx ex)
  liftA2 f x (ConstObservable (ObservableStateLiveOk y)) = mapObservableContent (\l -> liftA2 f l y) x

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
  type SelectorResult (Map k) = Identity
  applyDelta (ObservableMapReplace new) _ = new
  applyDelta (ObservableMapUpdate ops) old = applyObservableMapOperations ops old
  mergeDelta _ new@ObservableMapReplace{} = new
  mergeDelta (ObservableMapUpdate old) (ObservableMapUpdate new) = ObservableMapUpdate (Map.union new old)
  mergeDelta (ObservableMapReplace old) (ObservableMapUpdate new) = ObservableMapReplace (applyObservableMapOperations new old)
  toInitialDelta = ObservableMapReplace
  initializeFromDelta (ObservableMapReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta (ObservableMapUpdate _) = error "ObservableMap.initializeFromDelta: expected ObservableMapReplace"

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
  type SelectorResult Set = Identity
  applyDelta (ObservableSetReplace new) _ = new
  applyDelta (ObservableSetUpdate ops) old = applyObservableSetOperations ops old
  mergeDelta _ new@ObservableSetReplace{} = new
  mergeDelta (ObservableSetUpdate old) (ObservableSetUpdate new) = ObservableSetUpdate (Set.union new old)
  mergeDelta (ObservableSetReplace old) (ObservableSetUpdate new) = ObservableSetReplace (applyObservableSetOperations new old)
  toInitialDelta = ObservableSetReplace
  initializeFromDelta (ObservableSetReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta _ = error "ObservableSet.initializeFromDelta: expected ObservableSetReplace"

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

mapObservableResultContent :: (ca va -> cb vb) -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb
mapObservableResultContent fn (ObservableResultOk result) = ObservableResultOk (fn result)
mapObservableResultContent _fn (ObservableResultEx ex) = ObservableResultEx ex

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

instance ObservableContainer c v => ObservableContainer (ObservableResult exceptions c) v where
  type Delta (ObservableResult exceptions c) = ObservableResultDelta exceptions c
  type Key (ObservableResult exceptions c) v = Key c v
  type SelectorResult (ObservableResult exceptions c) = (ObservableResult exceptions Identity)
  applyDelta (ObservableResultDeltaThrow ex) _ = ObservableResultEx ex
  applyDelta (ObservableResultDeltaOk delta) (ObservableResultOk old) = ObservableResultOk (applyDelta delta old)
  applyDelta (ObservableResultDeltaOk delta) _ = ObservableResultOk (initializeFromDelta delta)
  mergeDelta (ObservableResultDeltaOk old) (ObservableResultDeltaOk new) = ObservableResultDeltaOk (mergeDelta @c old new)
  mergeDelta _ new = new
  toInitialDelta (ObservableResultOk initial) = ObservableResultDeltaOk (toInitialDelta initial)
  toInitialDelta (ObservableResultEx ex) = ObservableResultDeltaThrow ex
  initializeFromDelta (ObservableResultDeltaOk initial) = ObservableResultOk (initializeFromDelta initial)
  initializeFromDelta (ObservableResultDeltaThrow ex) = ObservableResultEx ex
