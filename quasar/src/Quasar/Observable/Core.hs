{-# LANGUAGE CPP #-}
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
) where

import Control.Applicative
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.String (IsString(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type ToObservable :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c => ToObservable canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
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
      EvaluatedObservableChangeLoading -> ObservableChangeLoading
      EvaluatedObservableChangeLive -> ObservableChangeLive
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

  mapObservable# :: (v -> n) -> a -> Observable canLoad exceptions c n
  mapObservable# f x = Observable (MappedObservable f x)

  mapObservableContent#
    :: ObservableContainer d
    => (ObservableContent exceptions c v -> ObservableContent exceptions d n)
    -> a
    -> Observable canLoad exceptions d n
  mapObservableContent# f x = Observable (MappedStateObservable f x)

  count# :: a -> ObservableI canLoad exceptions Int64
  count# = undefined

  isEmpty# :: a -> ObservableI canLoad exceptions Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c) => a -> Selector c -> ObservableI canLoad exceptions (Maybe (Key c))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c) => a -> Selector c -> ObservableI canLoad exceptions (Maybe (Key c, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key value) => a -> Selector value -> ObservableI canLoad exceptions (Maybe v)
  lookupValue# = undefined

  --query# :: a -> ObservableList canLoad exceptions (Bounds value) -> Observable canLoad exceptions c v
  --query# = undefined

--query :: ToObservable canLoad exceptions c v a => a -> ObservableList canLoad exceptions (Bounds c) -> Observable canLoad exceptions c v
--query = undefined

type Bounds value = (Bound value, Bound value)

data Bound c
  = ExcludingBound (Key c)
  | IncludingBound (Key c)
  | NoBound

data Selector c
  = Min
  | Max
  | Key (Key c)

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

mapObservable :: ToObservable canLoad exceptions c v a => (v -> f) -> a -> Observable canLoad exceptions c f
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
  ObservableChangeLoading :: ObservableChange Load exceptions c v
  ObservableChangeLoadingClear :: ObservableChange Load exceptions c v
  ObservableChangeLive :: ObservableChange canLoad exceptions c v
  ObservableChangeLiveThrow :: Ex exceptions -> ObservableChange canLoad exceptions c v
  ObservableChangeLiveDelta :: Delta c v -> ObservableChange canLoad exceptions c v

instance ObservableContainer c => Functor (ObservableChange canLoad exceptions c) where
  fmap _fn ObservableChangeLoading = ObservableChangeLoading
  fmap _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
  fmap _fn ObservableChangeLive = ObservableChangeLive
  fmap _fn (ObservableChangeLiveThrow ex) = ObservableChangeLiveThrow ex
  fmap fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fn <$> delta)

type EvaluatedObservableChange :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data EvaluatedObservableChange canLoad exceptions c v where
  EvaluatedObservableChangeLoading :: EvaluatedObservableChange Load exceptions c v
  EvaluatedObservableChangeLoadingClear :: EvaluatedObservableChange Load exceptions c v
  EvaluatedObservableChangeLive :: EvaluatedObservableChange canLoad exceptions c v
  EvaluatedObservableChangeLiveThrow :: Ex exceptions -> EvaluatedObservableChange canLoad exceptions c v
  EvaluatedObservableChangeLiveDelta :: Delta c v -> c v -> EvaluatedObservableChange canLoad exceptions c v

instance ObservableContainer c => Functor (EvaluatedObservableChange canLoad exceptions c) where
  fmap _fn EvaluatedObservableChangeLoading =
    EvaluatedObservableChangeLoading
  fmap _fn EvaluatedObservableChangeLoadingClear =
    EvaluatedObservableChangeLoadingClear
  fmap _fn EvaluatedObservableChangeLive =
    EvaluatedObservableChangeLive
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

type ObserverState :: CanLoad -> [Type] -> (Type -> Type) -> Type -> Type
data ObserverState canLoad exceptions c v where
  ObserverStateLoadingCleared :: ObserverState Load exceptions c v
  ObserverStateLoadingCached :: ObservableContent exceptions c v -> ObserverState Load exceptions c v
  ObserverStateLive :: ObservableContent exceptions c v -> ObserverState canLoad exceptions c v

type Loading :: CanLoad -> Type
data Loading canLoad where
  Live :: Loading canLoad
  Loading :: Loading Load

instance Semigroup (Loading canLoad) where
  Live <> Live = Live
  Loading <> _ = Loading
  _ <> Loading = Loading

applyObservableChange
  :: ObservableContainer c
  => ObservableChange canLoad exceptions c v
  -> ObserverState canLoad exceptions c v
  -> Maybe (EvaluatedObservableChange canLoad exceptions c v, ObserverState canLoad exceptions c v)
applyObservableChange ObservableChangeLoadingClear ObserverStateLoadingCleared =
  Nothing
applyObservableChange ObservableChangeLoadingClear _ =
  Just (EvaluatedObservableChangeLoadingClear, ObserverStateLoadingCleared)
applyObservableChange ObservableChangeLoading ObserverStateLoadingCleared =
  Nothing
applyObservableChange ObservableChangeLoading (ObserverStateLoadingCached _) =
  Nothing
applyObservableChange ObservableChangeLoading (ObserverStateLive state) =
  Just (EvaluatedObservableChangeLoading, ObserverStateLoadingCached state)
applyObservableChange ObservableChangeLive ObserverStateLoadingCleared =
  Nothing
applyObservableChange ObservableChangeLive (ObserverStateLoadingCached state) =
  Just (EvaluatedObservableChangeLive, ObserverStateLive state)
applyObservableChange ObservableChangeLive (ObserverStateLive _) =
  Nothing
applyObservableChange (ObservableChangeLiveThrow ex) _ =
  Just (EvaluatedObservableChangeLiveThrow ex, ObserverStateLive (Left ex))
applyObservableChange (ObservableChangeLiveDelta delta) (ObserverStateCached _ (Right old)) =
  let new = applyDelta delta old
  in Just (EvaluatedObservableChangeLiveDelta delta new, ObserverStateLive (Right new))
applyObservableChange (ObservableChangeLiveDelta delta) _ =
  let evaluated = initializeFromDelta delta
  in Just (EvaluatedObservableChangeLiveDelta delta evaluated, ObserverStateLive (Right evaluated))


createObserverState
  :: ObservableState canLoad exceptions c v
  -> ObserverState canLoad exceptions c v
createObserverState ObservableStateLoading = ObserverStateLoadingCleared
createObserverState (ObservableStateLive content) = ObserverStateLive content


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

instance ObservableContainer c => ToObservable canLoad exceptions c v (Observable canLoad exceptions c v) where
  toObservable = id

instance ObservableContainer c => Functor (Observable canLoad exceptions c) where
  fmap = mapObservable

instance (IsString v, Applicative c) => IsString (Observable canLoad exceptions c v) where
  fromString x = ConstObservable (pure (fromString x))


type ObservableContainer :: (Type -> Type) -> Constraint
class (Functor c, Functor (Delta c)) => ObservableContainer c where
  type Delta c :: Type -> Type
  type Key c
  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: Delta c v -> Delta c v -> Delta c v
  -- | Produce a delta from a content. The delta replaces any previous content when
  -- applied.
  toInitialDelta :: c v -> Delta c v
  initializeFromDelta :: Delta c v -> c v

instance ObservableContainer Identity where
  type Delta Identity = Identity
  type Key Identity = ()
  applyDelta new _ = new
  mergeDelta _ new = new
  toInitialDelta = id
  initializeFromDelta = id


evaluateObservable :: ToObservable canLoad exceptions c v a => a -> Observable canLoad exceptions Identity (c v)
evaluateObservable x = mapObservableContent (fmap Identity) x


data MappedObservable canLoad exceptions c v = forall prev a. IsObservable canLoad exceptions c prev a => MappedObservable (prev -> v) a

instance ObservableContainer c => ToObservable canLoad exceptions c v (MappedObservable canLoad exceptions c v)

instance ObservableContainer c => IsObservable canLoad exceptions c v (MappedObservable canLoad exceptions c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


data MappedStateObservable canLoad exceptions c v = forall d p a. IsObservable canLoad exceptions d p a => MappedStateObservable (ObservableContent exceptions d p -> ObservableContent exceptions c v) a

instance ObservableContainer c => ToObservable canLoad exceptions c v (MappedStateObservable canLoad exceptions c v)

instance ObservableContainer c => IsObservable canLoad exceptions c v (MappedStateObservable canLoad exceptions c v) where
  attachEvaluatedObserver# (MappedStateObservable fn observable) callback =
    fmap2 (mapObservableState fn) $ attachEvaluatedObserver# observable \final evaluatedChange ->
      callback final case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoading -> EvaluatedObservableChangeLoading
        EvaluatedObservableChangeLive -> EvaluatedObservableChangeLive
        EvaluatedObservableChangeLiveThrow ex ->
          case fn (Left ex) of
            Left ex -> EvaluatedObservableChangeLiveThrow ex
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
mapObservableContent :: (ToObservable canLoad exceptions d p a, ObservableContainer c) => (ObservableContent exceptions d p -> ObservableContent exceptions c v) -> a -> Observable canLoad exceptions c v
mapObservableContent fn x = case toObservable x of
  (ConstObservable wstate) -> ConstObservable (mapObservableState fn wstate)
  (Observable f) -> mapObservableContent# fn f

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapEvaluatedObservable :: (ToObservable canLoad exceptions d p a, ObservableContainer c) => (d p -> c v) -> a -> Observable canLoad exceptions c v
mapEvaluatedObservable fn = mapObservableContent (fmap fn)

mapObservableState :: (ObservableContent exceptions cp vp -> ObservableContent exceptions c v) -> ObservableState canLoad exceptions cp vp -> ObservableState canLoad exceptions c v
mapObservableState fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)


data LiftA2Observable w e c v = forall va vb a b. (IsObservable w e c va a, IsObservable w e c vb b) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c) => ToObservable canLoad exceptions c v (LiftA2Observable canLoad exceptions c v)

instance (Applicative c, ObservableContainer c) => IsObservable canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  readObservable# (LiftA2Observable fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, liftA2 fn x y)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: (IsObservable canWait exceptions ca va a, IsObservable canWait exceptions cb vb b, ObservableContainer c)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (Final -> ObservableChange canWait exceptions c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
attachEvaluatedMergeObserver mergeState =
  attachMergeObserver mergeState (fn mergeState) (fn (flip mergeState))
  where
    fn :: ObservableContainer c => (ca va -> cb vb -> c v) -> Delta ca va -> ca va -> cb vb -> Maybe (Delta c v)
    fn mergeState' _ x y = Just $ toInitialDelta $ mergeState' x y

data MergeState a canWait where
  MergeStateValid :: a canWait -> MergeState a canWait
  MergeStateException :: a canWait -> Either () () -> MergeState a canWait
  MergeStateCleared :: MergeState a Wait

data Unit1 a = Unit1

mapMergeState :: (a canWait -> b canWait) -> MergeState a canWait -> MergeState b canWait
mapMergeState f (MergeStateValid x) = MergeStateValid (f x)
mapMergeState f (MergeStateException x side) = MergeStateException (f x) side
mapMergeState _f MergeStateCleared = MergeStateCleared

type MergeFn canWait exceptions ca va cb vb c v
  = ObservableChangeOperation exceptions ca va
  -> State exceptions ca va
  -> State exceptions cb vb
  -> MergeState Unit1 canWait
  -> (ObservableChangeOperation exceptions c v, MergeState Unit1 canWait)

deltaToOperation :: Maybe (Delta c v) -> ObservableChangeOperation exceptions c v
deltaToOperation Nothing = NoChangeOperation
deltaToOperation (Just delta) = DeltaOperation delta

attachMergeObserver
  :: forall canWait exceptions ca va cb vb c v a b.
  (IsObservable canWait exceptions ca va a, IsObservable canWait exceptions cb vb b, ObservableContainer c)
  => (ca va -> cb vb -> c v)
  -> (Delta ca va -> ca va -> cb vb -> Maybe (Delta c v))
  -> (Delta cb vb -> cb vb -> ca va -> Maybe (Delta c v))
  -> a
  -> b
  -> (Final -> ObservableChange canWait exceptions c v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
attachMergeObserver mergeFn applyDeltaLeft applyDeltaRight fx fy callback = do
  mfixTVar \var -> do
    (disposerX, initialFinalX, initialX) <- attachStateObserver# fx \finalX changeWithStateX -> do
      (_, _, finalY, y, oldMerged) <- readTVar var
      let
        final = finalX && finalY
        (changeX, stateX) = deconstructChangeWithState changeWithStateX
        (change, merged) = applyMergeFn mergeLeft changeX stateX y oldMerged
      writeTVar var (finalX, stateX, finalY, y, merged)
      mapM_ (callback final) change

    (disposerY, initialFinalY, initialY) <- attachStateObserver# fy \finalY changeWithStateY -> do
      (finalX, x, _, _, oldMerged) <- readTVar var
      let
        final = finalX && finalY
        (changeY, stateY) = deconstructChangeWithState changeWithStateY
        (change, merged) = applyMergeFn mergeRight changeY stateY x oldMerged
      writeTVar var (finalX, x, finalY, stateY, merged)
      mapM_ (callback final) change

    let
      disposer = disposerX <> disposerY
      final = initialFinalX && initialFinalY
      (initialWaitingX, initialStateX) = deconstructWaitingWithState initialX
      (initialWaitingY, initialStateY) = deconstructWaitingWithState initialY
      initialWaiting = initialWaitingX <> initialWaitingY
      (initialMState, initialMergeState) = case (initialStateX, initialStateY) of
        (JustState (Left exX), JustState (Left _)) ->
          (JustState (Left exX), MergeStateException initialWaiting (Left ()))
        (JustState (Left exX), _) ->
          (JustState (Left exX), MergeStateException initialWaiting (Left ()))
        (_, JustState (Left exY)) ->
          (JustState (Left exY), MergeStateException initialWaiting (Right ()))
        (JustState (Right x), JustState (Right y)) ->
          (JustState (Right (mergeFn x y)), MergeStateValid initialWaiting)
        (NothingState, _) -> (NothingState, MergeStateCleared)
        (_, NothingState) -> (NothingState, MergeStateCleared)
      initialMerged = mkWaitingWithState initialWaiting initialMState
    pure ((disposer, final, initialMerged), (initialFinalX, initialX, initialFinalY, initialY, initialMergeState))
  where
    mergeLeft
      :: ObservableChangeOperation exceptions ca va
      -> State exceptions ca va
      -> State exceptions cb vb
      -> MergeState Unit1 canWait
      -> (ObservableChangeOperation exceptions c v, MergeState Unit1 canWait)
    mergeLeft NoChangeOperation _x _y mergeState = (NoChangeOperation, mergeState)
    mergeLeft (ThrowOperation exX) _x _y _ =
      (ThrowOperation exX, MergeStateException Unit1 (Left ()))
    mergeLeft (DeltaOperation delta) (Right x) (Right y) (MergeStateValid _) =
      (deltaToOperation (applyDeltaLeft delta x y), MergeStateValid Unit1)
    mergeLeft (DeltaOperation _delta) (Right x) (Right y) _ =
      (DeltaOperation (toInitialDelta (mergeFn x y)), MergeStateValid Unit1)
    mergeLeft (DeltaOperation _delta) (Right _) (Left _) mergeState@(MergeStateException _ (Right ())) =
      (NoChangeOperation, mergeState)
    mergeLeft (DeltaOperation _delta) (Right _) (Left exY) (MergeStateException _ (Left ())) =
      (ThrowOperation exY, MergeStateException Unit1 (Right ()))
    mergeLeft (DeltaOperation _delta) (Right _) (Left exY) _ =
      -- Unreachable code path
      (ThrowOperation exY, MergeStateException Unit1 (Right ()))
    mergeLeft (DeltaOperation _delta) (Left exX) _ _ =
      -- Law violating combination of delta and exception
      (ThrowOperation exX, MergeStateException Unit1 (Left ()))

    mergeRight
      :: ObservableChangeOperation exceptions cb vb
      -> State exceptions cb vb
      -> State exceptions ca va
      -> MergeState Unit1 canWait
      -> (ObservableChangeOperation exceptions c v, MergeState Unit1 canWait)
    mergeRight NoChangeOperation _x _y mergeState = (NoChangeOperation, mergeState)
    -- TODO right
    mergeRight (ThrowOperation exX) _x (Right _) _ =
      (ThrowOperation exX, MergeStateException Unit1 (Right ()))
    mergeRight (ThrowOperation _) _x (Left _) mergeState@(MergeStateException Unit1 (Left ())) =
      (NoChangeOperation, mergeState)
    mergeRight (ThrowOperation _exX) _x (Left exY) _ =
      -- Previous law violation
      (ThrowOperation exY, MergeStateException Unit1 (Left ()))

    mergeRight (DeltaOperation delta) (Right x) (Right y) (MergeStateValid _) =
      (deltaToOperation (applyDeltaRight delta x y), MergeStateValid Unit1)
    mergeRight (DeltaOperation _delta) (Right x) (Right y) _ =
      (DeltaOperation (toInitialDelta (mergeFn y x)), MergeStateValid Unit1)
    mergeRight (DeltaOperation _delta) (Right _) (Left _) mergeState@(MergeStateException _ (Left ())) =
      (NoChangeOperation, mergeState)
    mergeRight (DeltaOperation _delta) (Right _) (Left exY) (MergeStateException _ (Right ())) =
      (ThrowOperation exY, MergeStateException Unit1 (Left ()))
    mergeRight (DeltaOperation _delta) (Right _) (Left exY) _ =
      -- Unreachable code path
      (ThrowOperation exY, MergeStateException Unit1 (Left ()))
    mergeRight (DeltaOperation _delta) (Left exX) _ _ =
      -- Law violating combination of delta and exception
      (ThrowOperation exX, MergeStateException Unit1 (Right ()))

applyMergeFn
  :: forall canWait exceptions ca va cb vb c v.
  MergeFn canWait exceptions ca va cb vb c v
  -> ObservableChange canWait exceptions ca va
  -> WaitingWithState canWait exceptions ca va
  -> WaitingWithState canWait exceptions cb vb
  -> MergeState Waiting canWait
  -> (Maybe (ObservableChange canWait exceptions c v), MergeState Waiting canWait)
applyMergeFn mergeFn change wx wy mergeState  =
  let
    (_, stateX) = deconstructWaitingWithState wx
    (waitingY, stateY) = deconstructWaitingWithState wy
    (mergedChange, newMergeStateResult) =
      case change of
        ObservableChangeClear -> (ObservableChangeClear, MergeStateCleared)
        (ObservableChange waitingX op) ->
          case (stateX, stateY) of
            (JustState x, JustState y) ->
              let
                (newOp, newMergeState) = mergeFn op x y (mapMergeState (const Unit1) mergeState)
                waiting = (waitingX <> waitingY)
              in (ObservableChange waiting newOp, mapMergeState (const waiting) newMergeState)
            (NothingState, _) -> (ObservableChangeClear, MergeStateCleared)
            (_, NothingState) -> (ObservableChangeClear, MergeStateCleared)

    -- TODO deduplicate Clear

  in (Just mergedChange, newMergeStateResult)


data BindObservable canLoad exceptions c v = forall p a. IsObservable canLoad exceptions Identity p a => BindObservable a (p -> Observable canLoad exceptions c v)

data BindState
  = BindStateDone
  | BindStateWaiting
  | BindStateWaitingAttached TSimpleDisposer
  | BindStateLeftException

instance ObservableContainer c => ToObservable canLoad exceptions c v (BindObservable canLoad exceptions c v)

instance ObservableContainer c => IsObservable canLoad exceptions c v (BindObservable canLoad exceptions c v) where
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
    undefined

bindObservable
  :: ObservableContainer c
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

--readObservableI# :: IsObservable canLoad exceptions v a => a -> STMc NoRetry '[] (Final, WaitingWithState canLoad exceptions Identity v)
--readObservableI# x = fmap2 runIdentity $ readObservable# x
--
--attachObserverI# :: IsObservable canLoad exceptions v a => a -> (Final -> ObservableChange canLoad exceptions Identity v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canLoad exceptions Identity v)
--attachObserverI# x callback = undefined -- fmap3 runIdentity $ attachObserver# x (\final change -> callback final (runIdentity <$> change))


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

instance ObservableContainer (Map k) where
  type Delta (Map k) = (ObservableMapDelta k)
  type Key (Map k) = k
  applyDelta = undefined
  mergeDelta = undefined
  toInitialDelta = undefined
  initializeFromDelta = undefined

toObservableMap :: ToObservable canLoad exceptions (Map k) v a => a -> ObservableMap canLoad exceptions k v
toObservableMap = toObservable
