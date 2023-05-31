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

type ToObservable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c v => ToObservable canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  toObservable :: a -> Observable canLoad exceptions c v
  default toObservable :: IsObservable canLoad exceptions c v a => a -> Observable canLoad exceptions c v
  toObservable = Observable

type IsObservable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ToObservable canLoad exceptions c v a => IsObservable canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable# :: a -> STMc NoRetry '[] (Final, ObservableState canLoad exceptions c v)

  attachObserver#
    :: a
    -> (Final -> ObservableChange canLoad exceptions c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
  attachObserver# x callback = attachEvaluatedObserver# x \final evaluatedChange ->
    callback final case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveThrow ex -> ObservableChangeLiveThrow ex
      EvaluatedObservableChangeLiveDelta delta _ -> ObservableChangeLiveDelta delta

  attachEvaluatedObserver#
    :: a
    -> (Final -> EvaluatedObservableChange canLoad exceptions c v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
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

  mapObservable# :: ObservableFunctor c => (v -> n) -> a -> Observable canLoad exceptions c n
  mapObservable# f x = Observable (MappedObservable f x)

  mapObservableContent#
    :: ObservableContainer d n
    => (ObservableContent exceptions c v -> ObservableContent exceptions d n)
    -> a
    -> Observable canLoad exceptions d n
  mapObservableContent# f x = Observable (MappedStateObservable f x)

  count# :: a -> ObservableI canLoad exceptions Int64
  count# = undefined

  isEmpty# :: a -> ObservableI canLoad exceptions Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad exceptions (Maybe (Key c v))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad exceptions (Maybe (Key c v, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key c v) => a -> Selector c v -> ObservableI canLoad exceptions (Maybe v)
  lookupValue# = undefined

  --query# :: a -> ObservableList canLoad exceptions (Bounds value) -> Observable canLoad exceptions c v
  --query# = undefined

--query :: ToObservable canLoad exceptions c v a => a -> ObservableList canLoad exceptions (Bounds c) -> Observable canLoad exceptions c v
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
  :: (ToObservable NoLoad exceptions c v a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m (c v)
readObservable x = case toObservable x of
  (ConstObservable content) -> extractState content
  (Observable y) -> do
    (_final, content) <- liftSTMc $ readObservable# y
    extractState content
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => ObservableState NoLoad exceptions c v -> m (c v)
    extractState (ObservableStateLive content) = either throwEx pure content

attachObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canLoad exceptions c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
attachObserver x callback = liftSTMc
  case toObservable x of
    Observable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachEvaluatedObserver :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> EvaluatedObservableChange canLoad exceptions c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
attachEvaluatedObserver x callback = liftSTMc
  case toObservable x of
    Observable f -> attachEvaluatedObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToObservable canLoad exceptions c v a => a -> Bool
isCachedObservable x = case toObservable x of
  Observable f -> isCachedObservable# f
  ConstObservable _value -> True

mapObservable :: (ObservableFunctor c, ToObservable canLoad exceptions c v a) => (v -> f) -> a -> Observable canLoad exceptions c f
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


type ObservableContent exceptions c a = Either (Ex exceptions) (c a)

type ObservableChange :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data ObservableChange canLoad exceptions c v where
  ObservableChangeLoadingUnchanged :: ObservableChange Load exceptions c v
  ObservableChangeLoadingClear :: ObservableChange Load exceptions c v
  ObservableChangeLiveUnchanged :: ObservableChange canLoad exceptions c v
  ObservableChangeLiveThrow :: Ex exceptions -> ObservableChange canLoad exceptions c v
  ObservableChangeLiveDelta :: Delta c v -> ObservableChange canLoad exceptions c v

instance (Functor (Delta c)) => Functor (ObservableChange canLoad exceptions c) where
  fmap _fn ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  fmap _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
  fmap _fn ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  fmap _fn (ObservableChangeLiveThrow ex) = ObservableChangeLiveThrow ex
  fmap fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fn <$> delta)

type EvaluatedObservableChange :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data EvaluatedObservableChange canLoad exceptions c v where
  EvaluatedObservableChangeLoadingUnchanged :: EvaluatedObservableChange Load exceptions c v
  EvaluatedObservableChangeLoadingClear :: EvaluatedObservableChange Load exceptions c v
  EvaluatedObservableChangeLiveUnchanged :: EvaluatedObservableChange canLoad exceptions c v
  EvaluatedObservableChangeLiveThrow :: Ex exceptions -> EvaluatedObservableChange canLoad exceptions c v
  EvaluatedObservableChangeLiveDelta :: Delta c v -> c v -> EvaluatedObservableChange canLoad exceptions c v

instance (Functor c, Functor (Delta c)) => Functor (EvaluatedObservableChange canLoad exceptions c) where
  fmap _fn EvaluatedObservableChangeLoadingUnchanged =
    EvaluatedObservableChangeLoadingUnchanged
  fmap _fn EvaluatedObservableChangeLoadingClear =
    EvaluatedObservableChangeLoadingClear
  fmap _fn EvaluatedObservableChangeLiveUnchanged =
    EvaluatedObservableChangeLiveUnchanged
  fmap _fn (EvaluatedObservableChangeLiveThrow ex) =
    EvaluatedObservableChangeLiveThrow ex
  fmap fn (EvaluatedObservableChangeLiveDelta delta evaluated) =
    EvaluatedObservableChangeLiveDelta (fn <$> delta) (fn <$> evaluated)

type ObservableState :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data ObservableState canLoad exceptions c v where
  ObservableStateLoading :: ObservableState Load exceptions c v
  ObservableStateLive :: ObservableContent exceptions c v -> ObservableState canLoad exceptions c v

instance Functor c => Functor (ObservableState canLoad exceptions c) where
  fmap _fn ObservableStateLoading = ObservableStateLoading
  fmap fn (ObservableStateLive content) = ObservableStateLive (fn <<$>> content)

instance Applicative c => Applicative (ObservableState canLoad exceptions c) where
  pure x = ObservableStateLive (Right (pure x))
  liftA2 fn (ObservableStateLive fx) (ObservableStateLive fy) =
    ObservableStateLive (liftA2 (liftA2 fn) fx fy)
  liftA2 _fn ObservableStateLoading _ = ObservableStateLoading
  liftA2 _fn _ ObservableStateLoading = ObservableStateLoading

observableStateIsLoading :: ObservableState canLoad exceptions c v -> Loading canLoad
observableStateIsLoading ObservableStateLoading = Loading
observableStateIsLoading (ObservableStateLive _) = Live

type ObserverState :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data ObserverState canLoad exceptions c v where
  ObserverStateLoadingCleared :: ObserverState Load exceptions c v
  ObserverStateLoadingCached :: ObservableContent exceptions c v -> ObserverState Load exceptions c v
  ObserverStateLive :: ObservableContent exceptions c v -> ObserverState canLoad exceptions c v

{-# COMPLETE ObserverStateLoading, ObserverStateLive #-}

pattern ObserverStateLoading :: () => (canLoad ~ Load) => ObserverState canLoad exceptions c v
pattern ObserverStateLoading <- (observerStateIsLoading -> Loading)

observerStateIsLoading :: ObserverState canLoad exceptions c v -> Loading canLoad
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
  => ObservableChange canLoad exceptions c v
  -> ObserverState canLoad exceptions c v
  -> Maybe (EvaluatedObservableChange canLoad exceptions c v, ObserverState canLoad exceptions c v)
applyObservableChange ObservableChangeLoadingClear ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingClear _ = Just (EvaluatedObservableChangeLoadingClear, ObserverStateLoadingCleared)
applyObservableChange ObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (EvaluatedObservableChangeLoadingUnchanged, ObserverStateLoadingCached state)
applyObservableChange ObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (EvaluatedObservableChangeLiveUnchanged, ObserverStateLive state)
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyObservableChange (ObservableChangeLiveThrow ex) _ = Just (EvaluatedObservableChangeLiveThrow ex, ObserverStateLive (Left ex))
applyObservableChange (ObservableChangeLiveDelta delta) (ObserverStateCached _ (Right old)) =
  let new = applyDelta delta old
  in Just (EvaluatedObservableChangeLiveDelta delta new, ObserverStateLive (Right new))
applyObservableChange (ObservableChangeLiveDelta delta) _ =
  let evaluated = initializeFromDelta delta
  in Just (EvaluatedObservableChangeLiveDelta delta evaluated, ObserverStateLive (Right evaluated))

applyEvaluatedObservableChange
  :: EvaluatedObservableChange canLoad exceptions c v
  -> ObserverState canLoad exceptions c v
  -> Maybe (ObserverState canLoad exceptions c v)
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear _ = Just ObserverStateLoadingCleared
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (ObserverStateLoadingCached state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (ObserverStateLive state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveThrow ex) _ = Just (ObserverStateLive (Left ex))
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveDelta _delta evaluated) _ = Just (ObserverStateLive (Right evaluated))


createObserverState
  :: ObservableState canLoad exceptions c v
  -> ObserverState canLoad exceptions c v
createObserverState ObservableStateLoading = ObserverStateLoadingCleared
createObserverState (ObservableStateLive content) = ObserverStateLive content

toObservableState
  :: ObserverState canLoad exceptions c v
  -> ObservableState canLoad exceptions c v
toObservableState ObserverStateLoadingCleared = ObservableStateLoading
toObservableState (ObserverStateLoadingCached _) = ObservableStateLoading
toObservableState (ObserverStateLive content) = ObservableStateLive content


pattern ObserverStateCached :: Loading canLoad -> ObservableContent exceptions c v -> ObserverState canLoad exceptions c v
pattern ObserverStateCached loading state <- (deconstructObserverStateCached -> Just (loading, state)) where
  ObserverStateCached = constructObserverStateCached
{-# COMPLETE ObserverStateCached, ObserverStateLoadingCleared #-}

deconstructObserverStateCached :: ObserverState canLoad exceptions c v -> Maybe (Loading canLoad, ObservableContent exceptions c v)
deconstructObserverStateCached ObserverStateLoadingCleared = Nothing
deconstructObserverStateCached (ObserverStateLoadingCached content) = Just (Loading, content)
deconstructObserverStateCached (ObserverStateLive content) = Just (Live, content)

constructObserverStateCached :: Loading canLoad -> ObservableContent exceptions c v -> ObserverState canLoad exceptions c v
constructObserverStateCached Live content = ObserverStateLive content
constructObserverStateCached Loading content = ObserverStateLoadingCached content


type Observable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data Observable canLoad exceptions c v
  = forall a. IsObservable canLoad exceptions c v a => Observable a
  | ConstObservable (ObservableState canLoad exceptions c v)

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


evaluateObservable :: ToObservable canLoad exceptions c v a => a -> Observable canLoad exceptions Identity (c v)
evaluateObservable x = mapObservableContent (fmap Identity) x


data MappedObservable canLoad exceptions c v = forall prev a. IsObservable canLoad exceptions c prev a => MappedObservable (prev -> v) a

instance ObservableFunctor c => ToObservable canLoad exceptions c v (MappedObservable canLoad exceptions c v)

instance ObservableFunctor c => IsObservable canLoad exceptions c v (MappedObservable canLoad exceptions c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


data MappedStateObservable canLoad exceptions c v = forall d p a. IsObservable canLoad exceptions d p a => MappedStateObservable (ObservableContent exceptions d p -> ObservableContent exceptions c v) a

instance ObservableContainer c v => ToObservable canLoad exceptions c v (MappedStateObservable canLoad exceptions c v)

instance ObservableContainer c v => IsObservable canLoad exceptions c v (MappedStateObservable canLoad exceptions c v) where
  attachEvaluatedObserver# (MappedStateObservable fn observable) callback =
    fmap2 (mapObservableState fn) $ attachEvaluatedObserver# observable \final evaluatedChange ->
      callback final case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoadingUnchanged -> EvaluatedObservableChangeLoadingUnchanged
        EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
        EvaluatedObservableChangeLiveThrow ex ->
          case fn (Left ex) of
            Left newEx -> EvaluatedObservableChangeLiveThrow newEx
            Right new -> EvaluatedObservableChangeLiveDelta (toInitialDelta new) new
        EvaluatedObservableChangeLiveDelta _delta evaluated ->
          case fn (Right evaluated) of
            Left ex -> EvaluatedObservableChangeLiveThrow ex
            Right new -> EvaluatedObservableChangeLiveDelta (toInitialDelta new) new

  readObservable# (MappedStateObservable fn observable) =
    fmap2 (mapObservableState fn) $ readObservable# observable

  mapObservable# f1 (MappedStateObservable f2 observable) =
    toObservable (MappedStateObservable (fmap2 f1 . f2) observable)

  mapObservableContent# f1 (MappedStateObservable f2 observable) =
    toObservable (MappedStateObservable (f1 . f2) observable)

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapObservableContent :: (ToObservable canLoad exceptions d p a, ObservableContainer c v) => (ObservableContent exceptions d p -> ObservableContent exceptions c v) -> a -> Observable canLoad exceptions c v
mapObservableContent fn x = case toObservable x of
  (ConstObservable wstate) -> ConstObservable (mapObservableState fn wstate)
  (Observable f) -> mapObservableContent# fn f

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapEvaluatedObservable :: (ToObservable canLoad exceptions d p a, ObservableContainer c v) => (d p -> c v) -> a -> Observable canLoad exceptions c v
mapEvaluatedObservable fn = mapObservableContent (fmap fn)

mapObservableState :: (ObservableContent exceptions cp vp -> ObservableContent exceptions c v) -> ObservableState canLoad exceptions cp vp -> ObservableState canLoad exceptions c v
mapObservableState _fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)


data LiftA2Observable w e c v = forall va vb a b. (IsObservable w e c va a, IsObservable w e c vb b) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v) => ToObservable canLoad exceptions c v (LiftA2Observable canLoad exceptions c v)

instance (Applicative c, ObservableContainer c v) => IsObservable canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  readObservable# (LiftA2Observable fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, liftA2 fn x y)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: (IsObservable canLoad exceptions ca va a, IsObservable canLoad exceptions cb vb b, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (Final -> ObservableChange canLoad exceptions c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
attachEvaluatedMergeObserver mergeState =
  attachMergeObserver mergeState (fn mergeState) (fn (flip mergeState))
  where
    fn :: ObservableContainer c v => (ca va -> cb vb -> c v) -> Delta ca va -> ca va -> cb vb -> Maybe (Delta c v)
    fn mergeState' _ x y = Just $ toInitialDelta $ mergeState' x y

data MergeState canLoad where
  MergeStateLoadingCleared :: MergeState Load
  MergeStateValid :: Loading canLoad -> MergeState canLoad
  MergeStateException :: Loading canLoad -> MergeState canLoad

{-# COMPLETE MergeStateLoading, MergeStateLive #-}

pattern MergeStateLoading :: () => (canLoad ~ Load) => MergeState canLoad
pattern MergeStateLoading <- (mergeStateIsLoading -> Loading)

pattern MergeStateLive :: MergeState canLoad
pattern MergeStateLive <- (mergeStateIsLoading -> Live)

mergeStateIsLoading :: MergeState canLoad -> Loading canLoad
mergeStateIsLoading MergeStateLoadingCleared = Loading
mergeStateIsLoading (MergeStateValid loading) = loading
mergeStateIsLoading (MergeStateException loading) = loading

changeMergeState :: Loading canLoad -> MergeState canLoad -> MergeState canLoad
changeMergeState _loading MergeStateLoadingCleared = MergeStateLoadingCleared
changeMergeState loading (MergeStateValid _) = MergeStateValid loading
changeMergeState loading (MergeStateException _) = MergeStateException loading

attachMergeObserver
  :: forall canLoad exceptions ca va cb vb c v a b.
  (IsObservable canLoad exceptions ca va a, IsObservable canLoad exceptions cb vb b, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> (Delta ca va -> ca va -> cb vb -> Maybe (Delta c v))
  -> (Delta cb vb -> cb vb -> ca va -> Maybe (Delta c v))
  -> a
  -> b
  -> (Final -> ObservableChange canLoad exceptions c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canLoad exceptions c v)
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
        (ObservableStateLive (Right x), ObservableStateLive (Right y)) -> (ObservableStateLive (Right (mergeFn x y)), MergeStateValid Live)
        (ObservableStateLive (Left ex), ObservableStateLive _) -> (ObservableStateLive (Left ex), MergeStateException Live)
        (ObservableStateLive _, ObservableStateLive (Left ex)) -> (ObservableStateLive (Left ex), MergeStateException Live)
        (ObservableStateLoading, _) -> (ObservableStateLoading, MergeStateLoadingCleared)
        (_, ObservableStateLoading) -> (ObservableStateLoading, MergeStateLoadingCleared)
    pure ((disposer, final, initialState), (initialFinalX, createObserverState initialX, initialFinalY, createObserverState initialY, initialMergeState))
  where
    mergeLeft
      :: EvaluatedObservableChange canLoad exceptions ca va
      -> ObserverState canLoad exceptions ca va
      -> ObserverState canLoad exceptions cb vb
      -> MergeState canLoad
      -> Maybe (ObservableChange canLoad exceptions c v, MergeState canLoad)
    mergeLeft EvaluatedObservableChangeLoadingClear _ _ MergeStateLoadingCleared = Nothing
    mergeLeft EvaluatedObservableChangeLoadingClear _ _ _ = Just (ObservableChangeLoadingClear, MergeStateLoadingCleared)

    mergeLeft EvaluatedObservableChangeLoadingUnchanged _ _ MergeStateLoading = Nothing
    mergeLeft EvaluatedObservableChangeLoadingUnchanged _ _ merged = Just (ObservableChangeLoadingUnchanged, changeMergeState Loading merged)

    mergeLeft EvaluatedObservableChangeLiveUnchanged _ _ MergeStateLive = Nothing
    mergeLeft EvaluatedObservableChangeLiveUnchanged (ObserverStateLive (Left ex)) _ _ = Just (ObservableChangeLiveThrow ex, MergeStateException Live)
    mergeLeft EvaluatedObservableChangeLiveUnchanged _ ObserverStateLoading _ = Nothing
    mergeLeft EvaluatedObservableChangeLiveUnchanged _ (ObserverStateLive (Left _)) _ = Nothing
    mergeLeft EvaluatedObservableChangeLiveUnchanged _ _ merged = Just (ObservableChangeLiveUnchanged, changeMergeState Live merged)

    mergeLeft (EvaluatedObservableChangeLiveThrow ex) _ _ _ = Just (ObservableChangeLiveThrow ex, MergeStateException Live)

    mergeLeft (EvaluatedObservableChangeLiveDelta _ _) _ ObserverStateLoading _ = Nothing
    mergeLeft (EvaluatedObservableChangeLiveDelta _ _) _ (ObserverStateLive (Left _)) _ = Nothing
    mergeLeft (EvaluatedObservableChangeLiveDelta delta x) _ (ObserverStateLive (Right y)) (MergeStateValid _) = do
      mergedDelta <- applyDeltaLeft delta x y
      pure (ObservableChangeLiveDelta mergedDelta, MergeStateValid Live)
    mergeLeft (EvaluatedObservableChangeLiveDelta _delta x) _ (ObserverStateLive (Right y)) _ =
      Just (ObservableChangeLiveDelta (toInitialDelta (mergeFn x y)), MergeStateValid Live)

    mergeRight
      :: EvaluatedObservableChange canLoad exceptions cb vb
      -> ObserverState canLoad exceptions ca va
      -> ObserverState canLoad exceptions cb vb
      -> MergeState canLoad
      -> Maybe (ObservableChange canLoad exceptions c v, MergeState canLoad)
    mergeRight EvaluatedObservableChangeLoadingClear _ _ MergeStateLoadingCleared = Nothing
    mergeRight EvaluatedObservableChangeLoadingClear _ _ _ = Just (ObservableChangeLoadingClear, MergeStateLoadingCleared)

    mergeRight EvaluatedObservableChangeLoadingUnchanged _ _ MergeStateLoading = Nothing
    mergeRight EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive (Left _)) _ _ = Nothing
    mergeRight EvaluatedObservableChangeLoadingUnchanged _ _ merged = Just (ObservableChangeLoadingUnchanged, changeMergeState Loading merged)

    mergeRight _changeLive ObserverStateLoading _ _ = Nothing
    mergeRight _changeLive (ObserverStateLive (Left _ex)) _ _ = Nothing

    mergeRight EvaluatedObservableChangeLiveUnchanged _ _ MergeStateLive = Nothing
    mergeRight EvaluatedObservableChangeLiveUnchanged _ (ObserverStateLive (Left ex)) _ = Just (ObservableChangeLiveThrow ex, MergeStateException Live)
    mergeRight EvaluatedObservableChangeLiveUnchanged _ _ merged = Just (ObservableChangeLiveUnchanged, changeMergeState Live merged)

    mergeRight (EvaluatedObservableChangeLiveThrow ex) _ _ _ = Just (ObservableChangeLiveThrow ex, MergeStateException Live)

    mergeRight (EvaluatedObservableChangeLiveDelta delta y) (ObserverStateLive (Right x)) _ (MergeStateValid _) = do
      mergedDelta <- applyDeltaRight delta y x
      pure (ObservableChangeLiveDelta mergedDelta, MergeStateValid Live)
    mergeRight (EvaluatedObservableChangeLiveDelta _delta y) (ObserverStateLive (Right x)) _ _ =
      Just (ObservableChangeLiveDelta (toInitialDelta (mergeFn x y)), MergeStateValid Live)


data BindObservable canLoad exceptions c v = forall p a. IsObservable canLoad exceptions Identity p a => BindObservable a (p -> Observable canLoad exceptions c v)

data BindState canLoad exceptions c v where
  -- LHS cleared
  BindStateCleared :: BindState Load exceptions c v
  -- LHS exception
  BindStateException :: Loading canLoad -> BindState canLoad exceptions c v
  -- RHS attached
  BindStateAttachedLoading :: TSimpleDisposer -> Final -> BindRHS canLoad exceptions c v -> BindState canLoad exceptions c v
  BindStateAttachedLive :: TSimpleDisposer -> Final -> BindRHS canLoad exceptions c v -> BindState canLoad exceptions c v

data BindRHS canLoad exceptions c v where
  BindRHSCleared :: BindRHS Load exceptions c v
  BindRHSPendingException :: Loading canLoad -> Ex exceptions -> BindRHS canLoad exceptions c v
  BindRHSPendingDelta :: Loading canLoad -> Delta c v -> BindRHS canLoad exceptions c v
  -- Downstream observer has valid content
  BindRHSValid :: Loading canLoad -> BindRHS canLoad exceptions c v

reactivateBindRHS :: BindRHS canLoad exceptions c v -> Maybe (ObservableChange canLoad exceptions c v, BindRHS canLoad exceptions c v)
reactivateBindRHS (BindRHSPendingException Live ex) = Just (ObservableChangeLiveThrow ex, BindRHSValid Live)
reactivateBindRHS (BindRHSPendingDelta Live delta) = Just (ObservableChangeLiveDelta delta, BindRHSValid Live)
reactivateBindRHS (BindRHSValid Live) = Just (ObservableChangeLiveUnchanged, BindRHSValid Live)
reactivateBindRHS _ = Nothing

bindRHSSetLoading :: Loading canLoad -> BindRHS canLoad exceptions c v -> BindRHS canLoad exceptions c v
bindRHSSetLoading _loading BindRHSCleared = BindRHSCleared
bindRHSSetLoading loading (BindRHSPendingException _ ex) = BindRHSPendingException loading ex
bindRHSSetLoading loading (BindRHSPendingDelta _ delta) = BindRHSPendingDelta loading delta
bindRHSSetLoading loading (BindRHSValid _) = BindRHSValid loading

updateSuspendedBindRHS
  :: forall canLoad exceptions c v. ObservableContainer c v
  => ObservableChange canLoad exceptions c v
  -> BindRHS canLoad exceptions c v
  -> BindRHS canLoad exceptions c v
updateSuspendedBindRHS ObservableChangeLoadingClear _ = BindRHSCleared
updateSuspendedBindRHS ObservableChangeLoadingUnchanged rhs = bindRHSSetLoading Loading rhs
updateSuspendedBindRHS ObservableChangeLiveUnchanged rhs = bindRHSSetLoading Live rhs
updateSuspendedBindRHS (ObservableChangeLiveThrow ex) _ = BindRHSPendingException Live ex
updateSuspendedBindRHS (ObservableChangeLiveDelta delta) (BindRHSPendingDelta _ prevDelta) = BindRHSPendingDelta Live (mergeDelta @c prevDelta delta)
updateSuspendedBindRHS (ObservableChangeLiveDelta delta) _ = BindRHSPendingDelta Live delta

updateActiveBindRHS
  :: forall canLoad exceptions c v. ObservableContainer c v
  => ObservableChange canLoad exceptions c v
  -> BindRHS canLoad exceptions c v
  -> (ObservableChange canLoad exceptions c v, BindRHS canLoad exceptions c v)
updateActiveBindRHS ObservableChangeLoadingClear _ = (ObservableChangeLoadingClear, BindRHSCleared)
updateActiveBindRHS ObservableChangeLoadingUnchanged rhs = (ObservableChangeLoadingUnchanged, bindRHSSetLoading Loading rhs)
updateActiveBindRHS ObservableChangeLiveUnchanged (BindRHSPendingException _ ex) = (ObservableChangeLiveThrow ex, BindRHSValid Live)
updateActiveBindRHS ObservableChangeLiveUnchanged (BindRHSPendingDelta _ delta) = (ObservableChangeLiveDelta delta, BindRHSValid Live)
updateActiveBindRHS ObservableChangeLiveUnchanged rhs = (ObservableChangeLiveUnchanged, bindRHSSetLoading Live rhs)
updateActiveBindRHS (ObservableChangeLiveThrow ex) _ = (ObservableChangeLiveThrow ex, BindRHSValid Live)
updateActiveBindRHS (ObservableChangeLiveDelta delta) (BindRHSPendingDelta _ prevDelta) = (ObservableChangeLiveDelta (mergeDelta @c prevDelta delta), BindRHSValid Live)
updateActiveBindRHS (ObservableChangeLiveDelta delta) _ = (ObservableChangeLiveDelta delta, BindRHSValid Live)


instance ObservableContainer c v => ToObservable canLoad exceptions c v (BindObservable canLoad exceptions c v)

instance ObservableContainer c v => IsObservable canLoad exceptions c v (BindObservable canLoad exceptions c v) where
  readObservable# (BindObservable fx fn) = do
    (finalX, wx) <- readObservable# fx
    case wx of
      ObservableStateLoading -> pure (finalX, ObservableStateLoading)
      ObservableStateLive (Left ex) -> pure (finalX, ObservableStateLive (Left ex))
      ObservableStateLive (Right (Identity x)) ->
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
              BindStateException Loading -> pure ()
              BindStateException Live -> do
                writeTVar var (finalX, BindStateException Loading)
                callback finalX ObservableChangeLoadingUnchanged
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
              BindStateException Live -> pure ()
              BindStateException Loading -> do
                writeTVar var (finalX, BindStateException Live)
                callback finalX ObservableChangeLiveUnchanged
              BindStateAttachedLoading disposer finalY rhs -> do
                case reactivateBindRHS rhs of
                  Nothing -> writeTVar var (finalX, BindStateAttachedLive disposer finalY rhs)
                  Just (change, newRhs) -> do
                    writeTVar var (finalX, BindStateAttachedLive disposer finalY newRhs)
                    callback (finalX && finalY) change
              BindStateAttachedLive{} -> pure ()
          ObservableChangeLiveThrow ex -> do
            detach var
            writeTVar var (finalX, BindStateException Live)
            callback finalX (ObservableChangeLiveThrow ex)
          ObservableChangeLiveDelta (Identity x) -> do
            detach var
            (finalY, stateY, bindState) <- attach var (fn x)
            writeTVar var (finalX, bindState)
            callback (finalX && finalY) case stateY of
              ObservableStateLoading -> ObservableChangeLoadingClear
              ObservableStateLive (Left ex) -> ObservableChangeLiveThrow ex
              ObservableStateLive (Right evaluatedY) ->
                ObservableChangeLiveDelta (toInitialDelta evaluatedY)

      (initialFinalY, initial, bindState) <- case initialX of
        ObservableStateLoading -> pure (initialFinalX, ObservableStateLoading, BindStateCleared)
        ObservableStateLive (Left ex) -> pure (False, ObservableStateLive (Left ex), BindStateException Live)
        ObservableStateLive (Right (Identity x)) -> attach var (fn x)

      -- TODO should be disposed when sending final callback
      disposer <- newUnmanagedTSimpleDisposer (detach var)

      pure ((disposerX <> disposer, initialFinalX && initialFinalY, initial), (initialFinalX, bindState))
    where
      attach
        :: TVar (Final, BindState canLoad exceptions c v)
        -> Observable canLoad exceptions c v
        -> STMc NoRetry '[] (Final, ObservableState canLoad exceptions c v, BindState canLoad exceptions c v)
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

      detach :: TVar (Final, BindState canLoad exceptions c v) -> STMc NoRetry '[] ()
      detach var = detach' . snd =<< readTVar var

      detach' :: BindState canLoad exceptions c v -> STMc NoRetry '[] ()
      detach' (BindStateAttachedLoading disposer _ _) = disposeTSimpleDisposer disposer
      detach' (BindStateAttachedLive disposer _ _) = disposeTSimpleDisposer disposer
      detach' _ = pure ()

bindObservable
  :: ObservableContainer c v
  => Observable canLoad exceptions Identity a
  -> (a -> Observable canLoad exceptions c v)
  -> Observable canLoad exceptions c v
bindObservable (ConstObservable ObservableStateLoading) _fn =
  ConstObservable ObservableStateLoading
bindObservable (ConstObservable (ObservableStateLive (Left ex))) _fn =
  ConstObservable (ObservableStateLive (Left ex))
bindObservable (ConstObservable (ObservableStateLive (Right (Identity x)))) fn =
  fn x
bindObservable (Observable fx) fn = Observable (BindObservable fx fn)


-- ** Observable Identity

type ObservableI :: CanLoad -> [Type] -> Type -> Type
type ObservableI canLoad exceptions a = Observable canLoad exceptions Identity a
type ToObservableI :: CanLoad -> [Type] -> Type -> Type -> Constraint
type ToObservableI canLoad exceptions a = ToObservable canLoad exceptions Identity a

instance Applicative (Observable canLoad exceptions Identity) where
  pure x = ConstObservable (pure x)
  liftA2 f (Observable x) (Observable y) = Observable (LiftA2Observable f x y)
  liftA2 _f (ConstObservable ObservableStateLoading) _ = ConstObservable ObservableStateLoading
  liftA2 f (ConstObservable (ObservableStateLive x)) y = mapObservableContent (liftA2 (liftA2 f) x) y
  liftA2 _ _ (ConstObservable ObservableStateLoading) = ConstObservable ObservableStateLoading
  liftA2 f x (ConstObservable (ObservableStateLive y)) = mapObservableContent (\l -> liftA2 (liftA2 f) l y) x

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

toObservableMap :: ToObservable canLoad exceptions (Map k) v a => a -> ObservableMap canLoad exceptions k v
toObservableMap = toObservable


-- ** ObservableSet

type ObservableSet canLoad exceptions v = Observable canLoad exceptions Set v

type ToObservableSet canLoad exceptions v = ToObservable canLoad exceptions Set v

data ObservableSetDelta v
  = ObservableSetUpdate (Set (ObservableSetOperation v))
  | ObservableSetReplace (Set v)

data ObservableSetOperation v = ObservableSetInsert v | ObservableSetDelete v

instance ObservableContainer Set where
  type Delta Set = ObservableSetDelta
  type Key Set v = v
  applyDelta = undefined
  mergeDelta = undefined
  toInitialDelta = undefined
  initializeFromDelta = undefined

toObservableSet :: ToObservable canLoad exceptions Set v a => a -> ObservableSet canLoad exceptions v
toObservableSet = toObservable
