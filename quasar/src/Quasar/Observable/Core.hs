{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
  GeneralizedObservable(..),
  ToGeneralizedObservable(..),

  readObservable,
  attachObserver,
  attachStateObserver,
  mapObservable,
  isCachedObservable,

  mapObservableState,
  mapObservableContent,
  evaluateObservable,

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanWait(..),
#else
  CanWait,
  Wait,
  NoWait,
#endif

  Final,

  IsGeneralizedObservable(..),
  ObservableContainer(..),

  ObservableChange(..),
  WaitingWithState(..),
  withoutChange,
  ObservableChangeWithState(..),

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

type ToGeneralizedObservable :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ObservableContainer c => ToGeneralizedObservable canWait exceptions c v a | a -> canWait, a -> exceptions, a -> c, a -> v where
  toGeneralizedObservable :: a -> GeneralizedObservable canWait exceptions c v
  default toGeneralizedObservable :: IsGeneralizedObservable canWait exceptions c v a => a -> GeneralizedObservable canWait exceptions c v
  toGeneralizedObservable = GeneralizedObservable

type IsGeneralizedObservable :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ToGeneralizedObservable canWait exceptions c v a => IsGeneralizedObservable canWait exceptions c v a | a -> canWait, a -> exceptions, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachStateObserver#) #-}
  readObservable# :: a -> STMc NoRetry '[] (Final, WaitingWithState canWait exceptions c v)

  attachObserver# :: a -> (Final -> ObservableChange canWait exceptions c v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
  attachObserver# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateClear -> ObservableChangeClear
      ObservableChangeWithState waiting op _state -> ObservableChange waiting op

  attachStateObserver# :: a -> (Final -> ObservableChangeWithState canWait exceptions c v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
  attachStateObserver# x callback =
    mfixTVar \var -> do
      (disposer, final, initial) <- attachObserver# x \final change -> do
        merged <- stateTVar var \oldState ->
          let merged = applyObservableChange change oldState
          in (merged, withoutChange merged)
        callback final merged
      pure ((disposer, final, initial), initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: (v -> n) -> a -> GeneralizedObservable canWait exceptions c n
  mapObservable# f x = GeneralizedObservable (MappedObservable f x)

  mapObservableState#
    :: ObservableContainer d
    => (State exceptions c v -> State exceptions d n)
    -> a
    -> GeneralizedObservable canWait exceptions d n
  mapObservableState# f x = GeneralizedObservable (MappedStateObservable f x)

  count# :: a -> ObservableI canWait exceptions Int64
  count# = undefined

  isEmpty# :: a -> ObservableI canWait exceptions Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c) => a -> Selector c -> ObservableI canWait exceptions (Maybe (Key c))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c) => a -> Selector c -> ObservableI canWait exceptions (Maybe (Key c, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key value) => a -> Selector value -> ObservableI canWait exceptions (Maybe v)
  lookupValue# = undefined

  --query# :: a -> ObservableList canWait exceptions (Bounds value) -> GeneralizedObservable canWait exceptions c v
  --query# = undefined

--query :: ToGeneralizedObservable canWait exceptions c v a => a -> ObservableList canWait exceptions (Bounds c) -> GeneralizedObservable canWait exceptions c v
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
  :: (ToGeneralizedObservable NoWait exceptions c v a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m (c v)
readObservable x = case toGeneralizedObservable x of
  (ConstObservable state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => WaitingWithState NoWait exceptions c v -> m (c v)
    extractState (NotWaitingWithState z) = either throwEx pure z

attachObserver :: (ToGeneralizedObservable canWait exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
attachObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachStateObserver :: (ToGeneralizedObservable canWait exceptions c v a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions c v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, WaitingWithState canWait exceptions c v)
attachStateObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachStateObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToGeneralizedObservable canWait exceptions c v a => a -> Bool
isCachedObservable x = case toGeneralizedObservable x of
  GeneralizedObservable f -> isCachedObservable# f
  ConstObservable _value -> True

mapObservable :: ToGeneralizedObservable canWait exceptions c v a => (v -> f) -> a -> GeneralizedObservable canWait exceptions c f
mapObservable fn x = case toGeneralizedObservable x of
  (GeneralizedObservable f) -> mapObservable# fn f
  (ConstObservable state) -> ConstObservable (fn <$> state)

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanWait = Wait | NoWait
#else
data CanWait = Wait | NoWait
type Wait = 'Wait
type NoWait = 'NoWait
#endif


type State exceptions c a = Either (Ex exceptions) (c a)

type ObservableChangeOperation :: [Type] -> (Type -> Type) -> Type -> Type
data ObservableChangeOperation exceptions c v
  = NoChangeOperation
  | DeltaOperation (Delta c v)
  | ThrowOperation (Ex exceptions)

instance ObservableContainer c => Functor (ObservableChangeOperation exceptions c) where
  fmap _fn NoChangeOperation = NoChangeOperation
  fmap fn (DeltaOperation delta) = DeltaOperation (fn <$> delta)
  fmap _fn (ThrowOperation ex) = ThrowOperation ex

type Waiting :: CanWait -> Type
data Waiting canWait where
  NotWaiting :: Waiting canWait
  Waiting :: Waiting Wait

instance Semigroup (Waiting canWait) where
  NotWaiting <> NotWaiting = NotWaiting
  Waiting <> _ = Waiting
  _ <> Waiting = Waiting

type MaybeState :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data MaybeState canWait exceptions c a where
  JustState :: State exceptions c a -> MaybeState canWait exceptions c a
  NothingState :: MaybeState Wait exceptions c a

instance Functor c => Functor (MaybeState canWait exceptions c) where
  fmap fn (JustState state) = JustState (fn <<$>> state)
  fmap _fn NothingState = NothingState

instance Applicative c => Applicative (MaybeState canWait exceptions c) where
  pure x = JustState (Right (pure x))
  liftA2 f (JustState x) (JustState y) = JustState (liftA2 (liftA2 f) x y)
  liftA2 _ NothingState _ = NothingState
  liftA2 _ _ NothingState = NothingState

type WaitingWithState :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data WaitingWithState canWait exceptions c a where
  NotWaitingWithState :: State exceptions c a -> WaitingWithState canWait exceptions c a
  WaitingWithState :: Maybe (State exceptions c a) -> WaitingWithState Wait exceptions c a

pattern WaitingWithStatePattern :: Waiting canWait -> MaybeState canWait exceptions c a -> WaitingWithState canWait exceptions c a
pattern WaitingWithStatePattern waiting state <- (deconstructWaitingWithState -> (waiting, state)) where
  WaitingWithStatePattern = mkWaitingWithState
{-# COMPLETE WaitingWithStatePattern #-}

deconstructWaitingWithState :: WaitingWithState canWait exceptions c a -> (Waiting canWait, MaybeState canWait exceptions c a)
deconstructWaitingWithState (WaitingWithState (Just state)) = (Waiting, JustState state)
deconstructWaitingWithState (WaitingWithState Nothing) = (Waiting, NothingState)
deconstructWaitingWithState (NotWaitingWithState state) = (NotWaiting, JustState state)

mkWaitingWithState :: Waiting canWait -> MaybeState canWait exceptions c a -> WaitingWithState canWait exceptions c a
mkWaitingWithState _waiting NothingState = WaitingWithState Nothing -- Not having a state overrides to waiting
mkWaitingWithState waiting (JustState state) = toWaitingWithState waiting state

instance Functor c => Functor (WaitingWithState canWait exceptions c) where
  fmap fn (NotWaitingWithState x) = NotWaitingWithState (fn <<$>> x)
  fmap fn (WaitingWithState x) = WaitingWithState (fmap3 fn x)

instance Applicative c => Applicative (WaitingWithState canWait exceptions c) where
  pure x = NotWaitingWithState (Right (pure x))
  liftA2 fn (WaitingWithStatePattern xWaiting xState) (WaitingWithStatePattern yWaiting yState) =
    let
      waiting = xWaiting <> yWaiting
      state = liftA2 fn xState yState
    in WaitingWithStatePattern waiting state

type ObservableChange :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data ObservableChange canWait exceptions c v where
  ObservableChangeClear :: ObservableChange Wait exceptions c v
  ObservableChange :: Waiting canWait -> ObservableChangeOperation exceptions c v -> ObservableChange canWait exceptions c v

instance ObservableContainer c => Functor (ObservableChange canWait exceptions c) where
  fmap _fn ObservableChangeClear = ObservableChangeClear
  fmap fn (ObservableChange waiting op) = ObservableChange waiting (fn <$> op)

type ObservableChangeWithState :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data ObservableChangeWithState canWait exceptions c v where
  ObservableChangeWithStateClear :: ObservableChangeWithState Wait exceptions c v
  ObservableChangeWithState :: Waiting canWait -> ObservableChangeOperation exceptions c v -> State exceptions c v -> ObservableChangeWithState canWait exceptions c v


toWaitingWithState :: Waiting canWait -> State exceptions c v -> WaitingWithState canWait exceptions c v
toWaitingWithState Waiting state = WaitingWithState (Just state)
toWaitingWithState NotWaiting state = NotWaitingWithState state

applyObservableChange :: ObservableContainer c => ObservableChange canWait exceptions c v -> WaitingWithState canWait exceptions c v -> ObservableChangeWithState canWait exceptions c v
applyObservableChange ObservableChangeClear _ = ObservableChangeWithStateClear
applyObservableChange (ObservableChange waiting op@(ThrowOperation ex)) _ =
  ObservableChangeWithState waiting op (Left ex)
applyObservableChange (ObservableChange waiting op) (NotWaitingWithState state) =
  ObservableChangeWithState waiting op (applyOperation op state)
applyObservableChange (ObservableChange waiting op) (WaitingWithState (Just state)) =
  ObservableChangeWithState waiting op (applyOperation op state)
applyObservableChange (ObservableChange _waiting NoChangeOperation) (WaitingWithState Nothing) = ObservableChangeWithStateClear -- cannot change an uncached observable to NotWaiting
applyObservableChange (ObservableChange waiting op@(DeltaOperation delta)) (WaitingWithState Nothing) = ObservableChangeWithState waiting op (Right (initializeFromDelta delta))

applyOperation :: ObservableContainer c => ObservableChangeOperation exceptions c v -> State exceptions c v -> State exceptions c v
applyOperation NoChangeOperation x = x
applyOperation (DeltaOperation delta) (Left _) = Right (initializeFromDelta delta)
applyOperation (DeltaOperation delta) (Right x) = Right (applyDelta delta x)
applyOperation (ThrowOperation ex) _ = Left ex

withoutChange :: ObservableChangeWithState canWait exceptions c v -> WaitingWithState canWait exceptions c v
withoutChange ObservableChangeWithStateClear = WaitingWithState Nothing
withoutChange (ObservableChangeWithState waiting _op state) = toWaitingWithState waiting state

deconstructChangeWithState :: ObservableChangeWithState canWait exceptions c v -> (ObservableChange canWait exceptions c v, WaitingWithState canWait exceptions c v)
deconstructChangeWithState ObservableChangeWithStateClear = (ObservableChangeClear, WaitingWithState Nothing)
deconstructChangeWithState (ObservableChangeWithState waiting op state) = (ObservableChange waiting op, WaitingWithStatePattern waiting (JustState state))


type GeneralizedObservable :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data GeneralizedObservable canWait exceptions c v
  = forall a. IsGeneralizedObservable canWait exceptions c v a => GeneralizedObservable a
  | ConstObservable (WaitingWithState canWait exceptions c v)

instance ObservableContainer c => ToGeneralizedObservable canWait exceptions c v (GeneralizedObservable canWait exceptions c v) where
  toGeneralizedObservable = id

instance ObservableContainer c => Functor (GeneralizedObservable canWait exceptions c) where
  fmap = mapObservable

instance (IsString v, Applicative c) => IsString (GeneralizedObservable canWait exceptions c v) where
  fromString x = ConstObservable (pure (fromString x))


type ObservableContainer :: (Type -> Type) -> Constraint
class (Functor c, Functor (Delta c)) => ObservableContainer c where
  type Delta c :: Type -> Type
  type Key c
  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: Delta c v -> Delta c v -> Delta c v
  -- | Produce a delta from a state. The delta replaces any previous state when
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


evaluateObservable :: ToGeneralizedObservable canWait exceptions c v a => a -> GeneralizedObservable canWait exceptions Identity (c v)
evaluateObservable x = mapObservableState (fmap Identity) x


data MappedObservable canWait exceptions c v = forall prev a. IsGeneralizedObservable canWait exceptions c prev a => MappedObservable (prev -> v) a

instance ObservableContainer c => ToGeneralizedObservable canWait exceptions c v (MappedObservable canWait exceptions c v)

instance ObservableContainer c => IsGeneralizedObservable canWait exceptions c v (MappedObservable canWait exceptions c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toGeneralizedObservable $ MappedObservable (f1 . f2) upstream


data MappedStateObservable canWait exceptions c v = forall d p a. IsGeneralizedObservable canWait exceptions d p a => MappedStateObservable (State exceptions d p -> State exceptions c v) a

instance ObservableContainer c => ToGeneralizedObservable canWait exceptions c v (MappedStateObservable canWait exceptions c v)

instance ObservableContainer c => IsGeneralizedObservable canWait exceptions c v (MappedStateObservable canWait exceptions c v) where
  attachStateObserver# (MappedStateObservable fn observable) callback =
    fmap2 (mapWaitingWithState fn) $ attachStateObserver# observable \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateClear -> ObservableChangeWithStateClear
        ObservableChangeWithState waiting NoChangeOperation state ->
          ObservableChangeWithState waiting NoChangeOperation (fn state)
        ObservableChangeWithState waiting _op state ->
          let
            newState = fn state
            op = case newState of
              (Left ex) -> ThrowOperation ex
              (Right x) -> DeltaOperation (toInitialDelta x)
          in ObservableChangeWithState waiting op newState

  readObservable# (MappedStateObservable fn observable) =
    fmap2 (mapWaitingWithState fn) $ readObservable# observable

  mapObservable# f1 (MappedStateObservable f2 observable) =
    toGeneralizedObservable (MappedStateObservable (fmap2 f1 . f2) observable)

  mapObservableState# f1 (MappedStateObservable f2 observable) =
    toGeneralizedObservable (MappedStateObservable (f1 . f2) observable)

-- | Apply a function to an observable that can replace the whole state. The
-- mapped observable is always fully evaluated.
mapObservableState :: (ToGeneralizedObservable canWait exceptions d p a, ObservableContainer c) => (State exceptions d p -> State exceptions c v) -> a -> GeneralizedObservable canWait exceptions c v
mapObservableState fn x = case toGeneralizedObservable x of
  (ConstObservable wstate) -> ConstObservable (mapWaitingWithState fn wstate)
  (GeneralizedObservable f) -> mapObservableState# fn f

-- | Apply a function to an observable that can replace the whole content. The
-- mapped observable is always fully evaluated.
mapObservableContent :: (ToGeneralizedObservable canWait exceptions d p a, ObservableContainer c) => (d p -> c v) -> a -> GeneralizedObservable canWait exceptions c v
mapObservableContent fn = mapObservableState (fmap fn)

mapWaitingWithState :: (State exceptions cp vp -> State exceptions c v) -> WaitingWithState canWait exceptions cp vp -> WaitingWithState canWait exceptions c v
mapWaitingWithState fn (WaitingWithState mstate) = WaitingWithState (fn <$> mstate)
mapWaitingWithState fn (NotWaitingWithState state) = NotWaitingWithState (fn state)


data LiftA2Observable w e c v = forall va vb a b. (IsGeneralizedObservable w e c va a, IsGeneralizedObservable w e c vb b) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c) => ToGeneralizedObservable canWait exceptions c v (LiftA2Observable canWait exceptions c v)

instance (Applicative c, ObservableContainer c) => IsGeneralizedObservable canWait exceptions c v (LiftA2Observable canWait exceptions c v) where
  readObservable# (LiftA2Observable fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, liftA2 fn x y)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: (IsGeneralizedObservable canWait exceptions ca va a, IsGeneralizedObservable canWait exceptions cb vb b, ObservableContainer c)
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
  (IsGeneralizedObservable canWait exceptions ca va a, IsGeneralizedObservable canWait exceptions cb vb b, ObservableContainer c)
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

-- ** Observable Identity

type ObservableI :: CanWait -> [Type] -> Type -> Type
type ObservableI canWait exceptions a = GeneralizedObservable canWait exceptions Identity a
type ToObservableI :: CanWait -> [Type] -> Type -> Type -> Constraint
type ToObservableI canWait exceptions a = ToGeneralizedObservable canWait exceptions Identity a

instance Applicative (GeneralizedObservable canWait exceptions Identity) where
  pure x = ConstObservable (pure x)
  liftA2 f (GeneralizedObservable x) (GeneralizedObservable y) = GeneralizedObservable (LiftA2Observable f x y)
  liftA2 _f (ConstObservable (WaitingWithState _)) _ = ConstObservable (WaitingWithState Nothing)
  liftA2 f (ConstObservable (NotWaitingWithState x)) y = mapObservableState (liftA2 (liftA2 f) x) y
  liftA2 _ _ (ConstObservable (WaitingWithState _)) = ConstObservable (WaitingWithState Nothing)
  liftA2 f x (ConstObservable (NotWaitingWithState y)) = mapObservableState (\l -> liftA2 (liftA2 f) l y) x

toObservableI :: ToObservableI canWait exceptions v a => a -> ObservableI canWait exceptions v
toObservableI = toGeneralizedObservable

-- ** ObservableMap

type ObservableMap canWait exceptions k v = GeneralizedObservable canWait exceptions (Map k) v

type ToObservableMap canWait exceptions k v = ToGeneralizedObservable canWait exceptions (Map k) v

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

toObservableMap :: ToGeneralizedObservable canWait exceptions (Map k) v a => a -> ObservableMap canWait exceptions k v
toObservableMap = toGeneralizedObservable
