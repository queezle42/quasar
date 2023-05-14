{-# LANGUAGE CPP #-}
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

  -- * Identity observable (single value without partial updats)
  Observable(..),
  ToObservable,
  toObservable,
  IsObservable,
) where

import Control.Applicative
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type ToGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Constraint
class ObservableContainer value => ToGeneralizedObservable canWait exceptions value a | a -> canWait, a -> exceptions, a -> value where
  toGeneralizedObservable :: a -> GeneralizedObservable canWait exceptions value
  default toGeneralizedObservable :: IsGeneralizedObservable canWait exceptions value a => a -> GeneralizedObservable canWait exceptions value
  toGeneralizedObservable = GeneralizedObservable

type IsGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Constraint
class ToGeneralizedObservable canWait exceptions value a => IsGeneralizedObservable canWait exceptions value a | a -> canWait, a -> exceptions, a -> value where
  {-# MINIMAL readObservable#, (attachObserver# | attachStateObserver#) #-}
  readObservable# :: a -> STMc NoRetry '[] (Final, WaitingWithState canWait exceptions value)

  attachObserver# :: a -> (Final -> ObservableChange canWait exceptions value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions value)
  attachObserver# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateClear -> ObservableChangeClear
      ObservableChangeWithState (WaitingWithState _) op -> ObservableChange Waiting op
      ObservableChangeWithState (NotWaitingWithState _) op -> ObservableChange NotWaiting op

  attachStateObserver# :: a -> (Final -> ObservableChangeWithState canWait exceptions value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, WaitingWithState canWait exceptions value)
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

  mapObservable# :: value ~ Identity prev => (prev -> next) -> a -> Observable canWait exceptions next
  mapObservable# f x = Observable (GeneralizedObservable (MappedObservable f x))

  --mapObservableDelta# :: ObservableContainer newValue => (Delta value -> Delta newValue) -> (value -> newValue) -> a -> GeneralizedObservable canWait exceptions newValue
  --mapObservableDelta# fd fn x = GeneralizedObservable (DeltaMappedObservable fd fn x)

  count# :: a -> Observable canRetry exceptions Int64
  count# = undefined

  isEmpty# :: a -> Observable canRetry exceptions Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key value) => a -> Selector value -> Observable canRetry exceptions (Maybe (Key value))
  lookupKey# = undefined

  lookupItem# :: Ord (Key value) => a -> Selector value -> Observable canRetry exceptions (Maybe (Key value, Value value))
  lookupItem# = undefined

  lookupValue# :: Ord (Key value) => a -> Selector value -> Observable canRetry exceptions (Maybe (Value value))
  lookupValue# = undefined

  query# :: a -> ObservableList canWait exceptions (Bounds value) -> GeneralizedObservable canWait exceptions value
  query# = undefined

query :: ToGeneralizedObservable canWait exceptions value a => a -> ObservableList canWait exceptions (Bounds value) -> GeneralizedObservable canWait exceptions value
query = undefined

type Bounds value = (Bound value, Bound value)

data Bound value
  = ExcludingBound (Key value)
  | IncludingBound (Key value)
  | NoBound

data Selector value
  = Min
  | Max
  | Key (Key value)

readObservable
  :: (ToGeneralizedObservable NoWait exceptions value a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m value
readObservable x = case toGeneralizedObservable x of
  (ConstObservable state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => WaitingWithState NoWait exceptions a -> m a
    extractState (NotWaitingWithState z) = either throwEx pure z

attachObserver :: (ToGeneralizedObservable canWait exceptions value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, WaitingWithState canWait exceptions value)
attachObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachStateObserver :: (ToGeneralizedObservable canWait exceptions value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, WaitingWithState canWait exceptions value)
attachStateObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachStateObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToGeneralizedObservable canWait exceptions value a => a -> Bool
isCachedObservable x = case toGeneralizedObservable x of
  GeneralizedObservable f -> isCachedObservable# f
  ConstObservable _value -> True

mapObservable :: ToObservable canWait exceptions value a => (value -> f) -> a -> Observable canWait exceptions f
mapObservable fn x = case toGeneralizedObservable x of
  (GeneralizedObservable f) -> mapObservable# fn f
  (ConstObservable state) -> Observable (ConstObservable (fn <<$>> state))

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanWait = Wait | NoWait
#else
data CanWait = Wait | NoWait
type Wait = 'Wait
type NoWait = 'NoWait
#endif


type State exceptions value = Either (Ex exceptions) value

type ObservableChangeOperation :: [Type] -> Type -> Type
data ObservableChangeOperation exceptions value
  = NoChangeOperation
  | DeltaOperation (Delta value)
  | ReplaceOperation (State exceptions value)

type Waiting :: CanWait -> Type
data Waiting canWait where
  NotWaiting :: Waiting canWait
  Waiting :: Waiting Wait

type MaybeState :: CanWait -> [Type] -> Type -> Type
data MaybeState canWait exceptions value where
  JustState :: State exceptions value -> MaybeState canWait exceptions value
  NothingState :: MaybeState Wait exceptions value

instance Functor (MaybeState canWait exceptions) where
  fmap fn (JustState state) = JustState (fn <$> state)
  fmap _fn NothingState = NothingState

type WaitingWithState :: CanWait -> [Type] -> Type -> Type
data WaitingWithState canWait exceptions value where
  NotWaitingWithState :: State exceptions value -> WaitingWithState canWait exceptions value
  WaitingWithState :: Maybe (State exceptions value) -> WaitingWithState Wait exceptions value

instance Functor (WaitingWithState canWait exceptions) where
  fmap fn (NotWaitingWithState x) = NotWaitingWithState (fn <$> x)
  fmap fn (WaitingWithState x) = WaitingWithState (fn <<$>> x)

type ObservableChange :: CanWait -> [Type] -> Type -> Type
data ObservableChange canWait exceptions value where
  ObservableChangeClear :: ObservableChange Wait exceptions value
  ObservableChange :: Waiting canWait -> ObservableChangeOperation exceptions value -> ObservableChange canWait exceptions value

type ObservableChangeWithState :: CanWait -> [Type] -> Type -> Type
data ObservableChangeWithState canWait exceptions value where
  ObservableChangeWithStateClear :: ObservableChangeWithState Wait exceptions value
  ObservableChangeWithState :: WaitingWithState canWait exceptions value -> ObservableChangeOperation exceptions value -> ObservableChangeWithState canWait exceptions value


toState :: WaitingWithState canWait exceptions value -> Maybe (State exceptions value)
toState (WaitingWithState x) = x
toState (NotWaitingWithState x) = Just x

toWaitingWithState :: Waiting canWait -> State exceptions value -> WaitingWithState canWait exceptions value
toWaitingWithState Waiting state = WaitingWithState (Just state)
toWaitingWithState NotWaiting state = NotWaitingWithState state

applyObservableChange :: ObservableContainer value => ObservableChange canWait exceptions value -> WaitingWithState canWait exceptions value -> ObservableChangeWithState canWait exceptions value
applyObservableChange ObservableChangeClear _ = ObservableChangeWithStateClear
applyObservableChange (ObservableChange waiting op@(ReplaceOperation state)) _ =
  ObservableChangeWithState (toWaitingWithState waiting state) op
applyObservableChange (ObservableChange waiting op) (NotWaitingWithState state) =
  ObservableChangeWithState (toWaitingWithState waiting (applyOperation op state)) op
applyObservableChange (ObservableChange waiting op) (WaitingWithState (Just state)) =
  ObservableChangeWithState (toWaitingWithState waiting (applyOperation op state)) op
applyObservableChange (ObservableChange _ _) (WaitingWithState Nothing) = ObservableChangeWithStateClear

applyOperation :: ObservableContainer value => ObservableChangeOperation exceptions value -> State exceptions value -> State exceptions value
applyOperation NoChangeOperation x = x
applyOperation (DeltaOperation delta) state = applyDelta delta <$> state
applyOperation (ReplaceOperation state) _ = state

withoutChange :: ObservableChangeWithState canWait exceptions value -> WaitingWithState canWait exceptions value
withoutChange ObservableChangeWithStateClear = WaitingWithState Nothing
withoutChange (ObservableChangeWithState waitingWithState op) = waitingWithState


type GeneralizedObservable :: CanWait -> [Type] -> Type -> Type
data GeneralizedObservable canWait exceptions value
  = forall a. IsGeneralizedObservable canWait exceptions value a => GeneralizedObservable a
  | ConstObservable (WaitingWithState canWait exceptions value)

instance ObservableContainer value => ToGeneralizedObservable canWait exceptions value (GeneralizedObservable canWait exceptions value) where
  toGeneralizedObservable = id

class ObservableContainer value where
  type Delta value
  type Key value
  type Value value
  applyDelta :: Delta value -> value -> value
  mergeDelta :: Delta value -> Delta value -> Delta value

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions value a => a -> Some (IsObservable canWait exceptions value)
  evaluateObservable# x = Some (EvaluatedObservable x)

instance ObservableContainer (Identity a) where
  type Delta (Identity a) = a
  type Key (Identity a) = ()
  type Value (Identity a) = a
  applyDelta new _ = Identity new
  mergeDelta _ new = new


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type
data EvaluatedObservable canWait exceptions value = forall a. IsGeneralizedObservable canWait exceptions value a => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions (Identity value) (EvaluatedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions (Identity value) (EvaluatedObservable canWait exceptions value) where
  readObservable# (EvaluatedObservable x) = fmap3 Identity $ readObservable# x
  attachStateObserver# (EvaluatedObservable @a x) callback =
    fmap3 Identity $ attachStateObserver# @a x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateClear -> ObservableChangeWithStateClear
        ObservableChangeWithState wstate NoChangeOperation ->
          ObservableChangeWithState (Identity <$> wstate) NoChangeOperation
        ObservableChangeWithState (WaitingWithState Nothing) _op ->
          ObservableChangeWithStateClear
        ObservableChangeWithState (WaitingWithState (Just state)) _op ->
          ObservableChangeWithState (WaitingWithState (Just (Identity <$> state))) (ReplaceOperation (Identity <$> state))
        ObservableChangeWithState (NotWaitingWithState state) _op ->
            ObservableChangeWithState (NotWaitingWithState (Identity <$> state)) (ReplaceOperation (Identity <$> state))


--data DeltaMappedObservable canWait exceptions value = forall oldValue a. IsGeneralizedObservable canWait exceptions oldValue a => DeltaMappedObservable (Delta oldValue -> Delta value) (oldValue -> value) a
--
--instance ObservableContainer value => ToGeneralizedObservable canWait exceptions value (DeltaMappedObservable canWait exceptions value)
--
--instance ObservableContainer value => IsGeneralizedObservable canWait exceptions value (DeltaMappedObservable canWait exceptions value) where
--  attachObserver# (DeltaMappedObservable deltaFn valueFn observable) callback =
--    fmap3 valueFn $ attachObserver# observable \final change ->
--      callback final (deltaFn <$> change)
--  readObservable# (DeltaMappedObservable _deltaFn valueFn observable) =
--    fmap3 valueFn $ readObservable# observable
--  mapObservableDelta# fd1 fn1 (DeltaMappedObservable fd2 fn2 x) = GeneralizedObservable (DeltaMappedObservable (fd1 . fd2) (fn1 . fn2) x)


-- ** Observable

type Observable :: CanWait -> [Type] -> Type -> Type
newtype Observable canWait exceptions a = Observable (GeneralizedObservable canWait exceptions (Identity a))
type ToObservable canWait exceptions a = ToGeneralizedObservable canWait exceptions (Identity a)
type IsObservable canWait exceptions a = IsGeneralizedObservable canWait exceptions (Identity a)

instance ToGeneralizedObservable canWait exceptions (Identity value) (Observable canWait exceptions value) where
  toGeneralizedObservable (Observable x) = x

instance Functor (Observable canWait exceptions) where
  fmap f (Observable x) = mapObservable f x

instance Applicative (Observable canWait exceptions) where
  pure value = Observable (ConstObservable (NotWaitingWithState (Right (Identity value))))
  liftA2 = undefined

instance Monad (Observable canWait exceptions) where
  (>>=) = undefined

toObservable :: ToObservable canWait exceptions value a => a -> Observable canWait exceptions value
toObservable x = Observable (toGeneralizedObservable x)


data MappedObservable canWait exceptions value = forall prev a. IsObservable canWait exceptions prev a => MappedObservable (prev -> value) a

instance ToGeneralizedObservable canWait exceptions (Identity value) (MappedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions (Identity value) (MappedObservable canWait exceptions value) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap4 fn $ attachObserver# observable \final change ->
      undefined -- callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap4 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


-- * Some

data Some c = forall a. c a => Some a
