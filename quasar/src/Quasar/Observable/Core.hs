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
  ToObservable(..),

  readObservable,
  attachObserver,
  attachEvaluatedObserver,
  mapObservable,
  isCachedObservable,

  mapObservableContent,
  mapEvaluatedObservable,
  evaluateObservable,

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanLoad(..),
#else
  CanLoad,
  Load,
  NoLoad,
#endif


  IsObservable(..),
  ObservableContainer(..),

  -- ** Additional types
  Final,
  ObservableContent,
  ObservableChange(..),
  EvaluatedObservableChange(..),
  ObservableState(..),
  ObserverState(..),
  createObserverState,
  toObservableState,
  applyObservableChange,
  applyEvaluatedObservableChange,

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

type ToObservable :: CanLoad -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c v => ToObservable canLoad c v a | a -> canLoad, a -> c, a -> v where
  toObservable :: a -> Observable canLoad c v
  default toObservable :: IsObservable canLoad c v a => a -> Observable canLoad c v
  toObservable = Observable

type IsObservable :: CanLoad -> (Type -> Type) -> Type -> Type -> Constraint
class ToObservable canLoad c v a => IsObservable canLoad c v a | a -> canLoad, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable# :: a -> STMc NoRetry '[] (Final, ObservableState canLoad c v)

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

  mapObservable# :: ObservableFunctor c => (v -> n) -> a -> Observable canLoad c n
  mapObservable# f x = Observable (MappedObservable f x)

  mapObservableContent#
    :: ObservableContainer d n
    => (ObservableContent c v -> ObservableContent d n)
    -> a
    -> Observable canLoad d n
  mapObservableContent# f x = Observable (MappedStateObservable f x)

  count# :: a -> ObservableI canLoad Int64
  count# = undefined

  isEmpty# :: a -> ObservableI canLoad Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (Maybe (Key c v))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (Maybe (Key c v, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad (Maybe v)
  lookupValue# = undefined

  --query# :: a -> ObservableList canLoad (Bounds value) -> Observable canLoad c v
  --query# = undefined

--query :: ToObservable canLoad c v a => a -> ObservableList canLoad (Bounds c) -> Observable canLoad c v
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
  :: (ToObservable NoLoad c v a, MonadSTMc NoRetry '[] m)
  => a -> m (c v)
readObservable x = case toObservable x of
  (ConstObservable (ObservableStateLive content)) -> pure content
  (Observable y) -> do
    ~(_final, ObservableStateLive content) <- liftSTMc $ readObservable# y
    pure content

attachObserver :: (ToObservable canLoad c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canLoad c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad c v)
attachObserver x callback = liftSTMc
  case toObservable x of
    Observable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachEvaluatedObserver :: (ToObservable canLoad c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> EvaluatedObservableChange canLoad c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad c v)
attachEvaluatedObserver x callback = liftSTMc
  case toObservable x of
    Observable f -> attachEvaluatedObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToObservable canLoad c v a => a -> Bool
isCachedObservable x = case toObservable x of
  Observable f -> isCachedObservable# f
  ConstObservable _value -> True

mapObservable :: (ObservableFunctor c, ToObservable canLoad c v a) => (v -> f) -> a -> Observable canLoad c f
mapObservable fn x = case toObservable x of
  (Observable f) -> mapObservable# fn f
  (ConstObservable content) -> ConstObservable (fn <$> content)

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanLoad = Load | NoLoad
#else
data CanLoad = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad
#endif


type ObservableContent c a = c a

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

type ObservableState :: CanLoad -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: ObservableContent c v -> ObservableState canLoad c v

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
  ObserverStateLoadingCached :: ObservableContent c v -> ObserverState Load c v
  ObserverStateLive :: ObservableContent c v -> ObserverState canLoad c v

{-# COMPLETE ObserverStateLoading, ObserverStateLive #-}

pattern ObserverStateLoading :: () => (canLoad ~ Load) => ObserverState canLoad c v
pattern ObserverStateLoading <- (observerStateIsLoading -> Loading)

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


pattern ObserverStateCached :: Loading canLoad -> ObservableContent c v -> ObserverState canLoad c v
pattern ObserverStateCached loading state <- (deconstructObserverStateCached -> Just (loading, state)) where
  ObserverStateCached = constructObserverStateCached
{-# COMPLETE ObserverStateCached, ObserverStateLoadingCleared #-}

deconstructObserverStateCached :: ObserverState canLoad c v -> Maybe (Loading canLoad, ObservableContent c v)
deconstructObserverStateCached ObserverStateLoadingCleared = Nothing
deconstructObserverStateCached (ObserverStateLoadingCached content) = Just (Loading, content)
deconstructObserverStateCached (ObserverStateLive content) = Just (Live, content)

constructObserverStateCached :: Loading canLoad -> ObservableContent c v -> ObserverState canLoad c v
constructObserverStateCached Live content = ObserverStateLive content
constructObserverStateCached Loading content = ObserverStateLoadingCached content


type Observable :: CanLoad -> (Type -> Type) -> Type -> Type
data Observable canLoad c v
  = forall a. IsObservable canLoad c v a => Observable a
  | ConstObservable (ObservableState canLoad c v)

instance ObservableContainer c v => ToObservable canLoad c v (Observable canLoad c v) where
  toObservable = id

instance ObservableFunctor c => Functor (Observable canLoad c) where
  fmap = mapObservable

instance (IsString v, Applicative c) => IsString (Observable canLoad c v) where
  fromString x = ConstObservable (pure (fromString x))


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type Delta c :: Type -> Type
  type Key c v
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
  applyDelta new _ = new
  mergeDelta _ new = new
  toInitialDelta = id
  initializeFromDelta = id


evaluateObservable :: ToObservable canLoad c v a => a -> Observable canLoad Identity (c v)
evaluateObservable x = mapObservableContent Identity x


data MappedObservable canLoad c v = forall prev a. IsObservable canLoad c prev a => MappedObservable (prev -> v) a

instance ObservableFunctor c => ToObservable canLoad c v (MappedObservable canLoad c v)

instance ObservableFunctor c => IsObservable canLoad c v (MappedObservable canLoad c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


data MappedStateObservable canLoad c v = forall d p a. IsObservable canLoad d p a => MappedStateObservable (ObservableContent d p -> ObservableContent c v) a

instance ObservableContainer c v => ToObservable canLoad c v (MappedStateObservable canLoad c v)

instance ObservableContainer c v => IsObservable canLoad c v (MappedStateObservable canLoad c v) where
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
    fmap2 (mapObservableState fn) $ readObservable# observable

  mapObservable# f1 (MappedStateObservable f2 observable) =
    toObservable (MappedStateObservable (fmap f1 . f2) observable)

  mapObservableContent# f1 (MappedStateObservable f2 observable) =
    toObservable (MappedStateObservable (f1 . f2) observable)

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapObservableContent :: (ToObservable canLoad d p a, ObservableContainer c v) => (ObservableContent d p -> ObservableContent c v) -> a -> Observable canLoad c v
mapObservableContent fn x = case toObservable x of
  (ConstObservable wstate) -> ConstObservable (mapObservableState fn wstate)
  (Observable f) -> mapObservableContent# fn f

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapEvaluatedObservable :: (ToObservable canLoad d p a, ObservableContainer c v) => (d p -> c v) -> a -> Observable canLoad c v
mapEvaluatedObservable fn = mapObservableContent fn

mapObservableState :: (ObservableContent cp vp -> ObservableContent c v) -> ObservableState canLoad cp vp -> ObservableState canLoad c v
mapObservableState _fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)


data LiftA2Observable w c v = forall va vb a b. (IsObservable w c va a, IsObservable w c vb b) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v) => ToObservable canLoad c v (LiftA2Observable canLoad c v)

instance (Applicative c, ObservableContainer c v) => IsObservable canLoad c v (LiftA2Observable canLoad c v) where
  readObservable# (LiftA2Observable fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, liftA2 fn x y)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: (IsObservable canLoad ca va a, IsObservable canLoad cb vb b, ObservableContainer c v)
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
  (IsObservable canLoad ca va a, IsObservable canLoad cb vb b, ObservableContainer c v)
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


data BindObservable canLoad c v = forall p a. IsObservable canLoad Identity p a => BindObservable a (p -> Observable canLoad c v)

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


instance ObservableContainer c v => ToObservable canLoad c v (BindObservable canLoad c v)

instance ObservableContainer c v => IsObservable canLoad c v (BindObservable canLoad c v) where
  readObservable# (BindObservable fx fn) = do
    (finalX, wx) <- readObservable# fx
    case wx of
      ObservableStateLoading -> pure (finalX, ObservableStateLoading)
      ObservableStateLive (Identity x) ->
        case fn x of
          ConstObservable wy -> pure (finalX, wy)
          Observable fy -> do
            (finalY, wy) <- readObservable# fy
            pure (finalX && finalY, wy)

  attachObserver# (BindObservable fx fn) callback = do
    mfixTVar \var -> do
      (disposerX, initialFinalX, initialX) <- attachObserver# fx \finalX changeX -> do
        case changeX of
          ObservableChangeLoadingClear -> do
            detach var
            writeTVar var (finalX, BindStateCleared)
          ObservableChangeLoadingUnchanged -> do
            (_, bindState) <- readTVar var
            case bindState of
              BindStateCleared -> pure ()
              BindStateAttachedLive disposer finalY rhs@(BindRHSValid Live) -> do
                writeTVar var (finalX, BindStateAttachedLoading disposer finalY rhs)
                callback finalX ObservableChangeLoadingUnchanged
              BindStateAttachedLive disposer finalY rhs -> do
                writeTVar var (finalX, BindStateAttachedLoading disposer finalY rhs)
              BindStateAttachedLoading{} -> pure ()
          ObservableChangeLiveUnchanged -> do
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
          ObservableChangeLiveDelta (Identity x) -> do
            detach var
            (finalY, stateY, bindState) <- attach var (fn x)
            writeTVar var (finalX, bindState)
            callback (finalX && finalY) case stateY of
              ObservableStateLoading -> ObservableChangeLoadingClear
              ObservableStateLive evaluatedY ->
                ObservableChangeLiveDelta (toInitialDelta evaluatedY)

      (initialFinalY, initial, bindState) <- case initialX of
        ObservableStateLoading -> pure (initialFinalX, ObservableStateLoading, BindStateCleared)
        ObservableStateLive (Identity x) -> attach var (fn x)

      -- TODO should be disposed when sending final callback
      disposer <- newUnmanagedTSimpleDisposer (detach var)

      pure ((disposerX <> disposer, initialFinalX && initialFinalY, initial), (initialFinalX, bindState))
    where
      attach
        :: TVar (Final, BindState canLoad c v)
        -> Observable canLoad c v
        -> STMc NoRetry '[] (Final, ObservableState canLoad c v, BindState canLoad c v)
      attach var y = do
        case y of
          ConstObservable stateY -> pure (True, stateY, BindStateAttachedLive mempty True (BindRHSValid (observableStateIsLoading stateY)))
          Observable fy -> do
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
  :: ObservableContainer c v
  => Observable canLoad Identity a
  -> (a -> Observable canLoad c v)
  -> Observable canLoad c v
bindObservable (ConstObservable ObservableStateLoading) _fn =
  ConstObservable ObservableStateLoading
bindObservable (ConstObservable (ObservableStateLive (Identity x))) fn =
  fn x
bindObservable (Observable fx) fn = Observable (BindObservable fx fn)


-- ** Observable Identity

type ObservableI :: CanLoad -> Type -> Type
type ObservableI canLoad a = Observable canLoad Identity a
type ToObservableI :: CanLoad -> Type -> Type -> Constraint
type ToObservableI canLoad a = ToObservable canLoad Identity a

instance Applicative (Observable canLoad Identity) where
  pure x = ConstObservable (pure x)
  liftA2 f (Observable x) (Observable y) = Observable (LiftA2Observable f x y)
  liftA2 _f (ConstObservable ObservableStateLoading) _ = ConstObservable ObservableStateLoading
  liftA2 f (ConstObservable (ObservableStateLive x)) y = mapObservableContent (liftA2 f x) y
  liftA2 _ _ (ConstObservable ObservableStateLoading) = ConstObservable ObservableStateLoading
  liftA2 f x (ConstObservable (ObservableStateLive y)) = mapObservableContent (\l -> liftA2 f l y) x

instance Monad (Observable canLoad Identity) where
  (>>=) = bindObservable

toObservableI :: ToObservableI canLoad v a => a -> ObservableI canLoad v
toObservableI = toObservable


-- ** ObservableMap

type ObservableMap canLoad k v = Observable canLoad (Map k) v

type ToObservableMap canLoad k v = ToObservable canLoad (Map k) v

data ObservableMapDelta k v
  = ObservableMapUpdate (Map k (ObservableMapOperation v))
  | ObservableMapReplace (Map k v)

instance Functor (ObservableMapDelta k) where
  fmap f (ObservableMapUpdate x) = ObservableMapUpdate (f <<$>> x)
  fmap f (ObservableMapReplace x) = ObservableMapReplace (f <$> x)

data ObservableMapOperation v = ObservableMapInsert v | ObservableMapDelete

instance Functor ObservableMapOperation where
  fmap f (ObservableMapInsert x) = ObservableMapInsert (f x)
  fmap _f ObservableMapDelete = ObservableMapDelete

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
  applyDelta (ObservableMapReplace new) _ = new
  applyDelta (ObservableMapUpdate ops) old = applyObservableMapOperations ops old
  mergeDelta _ new@ObservableMapReplace{} = new
  mergeDelta (ObservableMapUpdate old) (ObservableMapUpdate new) = ObservableMapUpdate (Map.union new old)
  mergeDelta (ObservableMapReplace old) (ObservableMapUpdate new) = ObservableMapReplace (applyObservableMapOperations new old)
  toInitialDelta = ObservableMapReplace
  initializeFromDelta (ObservableMapReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta (ObservableMapUpdate _) = error "ObservableMap.initializeFromDelta: expected ObservableMapReplace"

toObservableMap :: ToObservable canLoad (Map k) v a => a -> ObservableMap canLoad k v
toObservableMap = toObservable


-- ** ObservableSet

type ObservableSet canLoad v = Observable canLoad Set v

type ToObservableSet canLoad v = ToObservable canLoad Set v

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
  applyDelta (ObservableSetReplace new) _ = new
  applyDelta (ObservableSetUpdate ops) old = applyObservableSetOperations ops old
  mergeDelta _ new@ObservableSetReplace{} = new
  mergeDelta (ObservableSetUpdate old) (ObservableSetUpdate new) = ObservableSetUpdate (Set.union new old)
  mergeDelta (ObservableSetReplace old) (ObservableSetUpdate new) = ObservableSetReplace (applyObservableSetOperations new old)
  toInitialDelta = ObservableSetReplace
  initializeFromDelta (ObservableSetReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta _ = error "ObservableSet.initializeFromDelta: expected ObservableSetReplace"

toObservableSet :: ToObservable canLoad Set v a => a -> ObservableSet canLoad v
toObservableSet = toObservable


-- ** Exception wrapper

data ObservableEx exceptions c v
  = ObservableExOk (c v)
  | ObservableExFailed (Ex exceptions)

data ObservableExDelta exceptions c v
  = ObservableExDeltaOk (Delta c v)
  | ObservableExDeltaThrow (Ex exceptions)

instance ObservableContainer c v => ObservableContainer (ObservableEx exceptions c) v where
  type Delta (ObservableEx exceptions c) = ObservableExDelta exceptions c
  type Key (ObservableEx exceptions c) v = Key c v
  applyDelta (ObservableExDeltaThrow ex) _ = ObservableExFailed ex
  applyDelta (ObservableExDeltaOk delta) (ObservableExOk old) = ObservableExOk (applyDelta delta old)
  applyDelta (ObservableExDeltaOk delta) _ = ObservableExOk (initializeFromDelta delta)
  mergeDelta (ObservableExDeltaOk old) (ObservableExDeltaOk new) = ObservableExDeltaOk (mergeDelta @c old new)
  mergeDelta _ new = new
  toInitialDelta (ObservableExOk initial) = ObservableExDeltaOk (toInitialDelta initial)
  toInitialDelta (ObservableExFailed ex) = ObservableExDeltaThrow ex
  initializeFromDelta (ObservableExDeltaOk initial) = ObservableExOk (initializeFromDelta initial)
  initializeFromDelta (ObservableExDeltaThrow ex) = ObservableExFailed ex
