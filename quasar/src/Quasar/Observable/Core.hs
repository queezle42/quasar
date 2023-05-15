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

  count# :: a -> Observable canRetry exceptions Int64
  count# = undefined

  isEmpty# :: a -> Observable canRetry exceptions Bool
  isEmpty# = undefined

  lookupKey# :: Ord (Key c) => a -> Selector c -> Observable canRetry exceptions (Maybe (Key c))
  lookupKey# = undefined

  lookupItem# :: Ord (Key c) => a -> Selector c -> Observable canRetry exceptions (Maybe (Key c, v))
  lookupItem# = undefined

  lookupValue# :: Ord (Key value) => a -> Selector value -> Observable canRetry exceptions (Maybe v)
  lookupValue# = undefined

  query# :: a -> ObservableList canWait exceptions (Bounds value) -> GeneralizedObservable canWait exceptions c v
  query# = undefined

query :: ToGeneralizedObservable canWait exceptions c v a => a -> ObservableList canWait exceptions (Bounds c) -> GeneralizedObservable canWait exceptions c v
query = undefined

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
  | ReplaceOperation (State exceptions c v)

instance ObservableContainer c => Functor (ObservableChangeOperation exceptions c) where
  fmap _fn NoChangeOperation = NoChangeOperation
  fmap fn (DeltaOperation delta) = DeltaOperation (fn <$> delta)
  fmap fn (ReplaceOperation state) = ReplaceOperation (fn <<$>> state)

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
pattern WaitingWithStatePattern waiting state <- (waitingWithStatePatternImpl -> (waiting, state)) where
  WaitingWithStatePattern _waiting NothingState = WaitingWithState Nothing -- Not having a state overrides to waiting
  WaitingWithStatePattern waiting (JustState state) = toWaitingWithState waiting state
{-# COMPLETE WaitingWithStatePattern #-}

waitingWithStatePatternImpl :: WaitingWithState canWait exceptions c a -> (Waiting canWait, MaybeState canWait exceptions c a)
waitingWithStatePatternImpl (WaitingWithState (Just state)) = (Waiting, JustState state)
waitingWithStatePatternImpl (WaitingWithState Nothing) = (Waiting, NothingState)
waitingWithStatePatternImpl (NotWaitingWithState state) = (NotWaiting, JustState state)

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


toState :: WaitingWithState canWait exceptions c v -> Maybe (State exceptions c v)
toState (WaitingWithState x) = x
toState (NotWaitingWithState x) = Just x

toWaitingWithState :: Waiting canWait -> State exceptions c v -> WaitingWithState canWait exceptions c v
toWaitingWithState Waiting state = WaitingWithState (Just state)
toWaitingWithState NotWaiting state = NotWaitingWithState state

applyObservableChange :: ObservableContainer c => ObservableChange canWait exceptions c v -> WaitingWithState canWait exceptions c v -> ObservableChangeWithState canWait exceptions c v
applyObservableChange ObservableChangeClear _ = ObservableChangeWithStateClear
applyObservableChange (ObservableChange waiting op@(ReplaceOperation state)) _ =
  ObservableChangeWithState waiting op state
applyObservableChange (ObservableChange waiting op) (NotWaitingWithState state) =
  ObservableChangeWithState waiting op (applyOperation op state)
applyObservableChange (ObservableChange waiting op) (WaitingWithState (Just state)) =
  ObservableChangeWithState waiting op (applyOperation op state)
applyObservableChange (ObservableChange _ _) (WaitingWithState Nothing) = ObservableChangeWithStateClear

applyOperation :: ObservableContainer c => ObservableChangeOperation exceptions c v -> State exceptions c v -> State exceptions c v
applyOperation NoChangeOperation x = x
applyOperation (DeltaOperation delta) state = applyDelta delta <$> state
applyOperation (ReplaceOperation state) _ = state

withoutChange :: ObservableChangeWithState canWait exceptions c v -> WaitingWithState canWait exceptions c v
withoutChange ObservableChangeWithStateClear = WaitingWithState Nothing
withoutChange (ObservableChangeWithState waiting _op state) = toWaitingWithState waiting state


type GeneralizedObservable :: CanWait -> [Type] -> (Type -> Type) -> Type -> Type
data GeneralizedObservable canWait exceptions c v
  = forall a. IsGeneralizedObservable canWait exceptions c v a => GeneralizedObservable a
  | ConstObservable (WaitingWithState canWait exceptions c v)

instance ObservableContainer c => ToGeneralizedObservable canWait exceptions c v (GeneralizedObservable canWait exceptions c v) where
  toGeneralizedObservable = id

instance ObservableContainer c => Functor (GeneralizedObservable canWait exceptions c) where
  fmap = mapObservable


type ObservableContainer :: (Type -> Type) -> Constraint
class (Functor c, Functor (Delta c)) => ObservableContainer c where
  type Delta c :: Type -> Type
  type Key c
  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: Delta c v -> Delta c v -> Delta c v

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions c v a => a -> Some (IsObservable canWait exceptions (c v))
  evaluateObservable# x = Some (EvaluatedObservable x)

instance ObservableContainer Identity where
  type Delta Identity = Void1
  type Key Identity = ()
  applyDelta = absurd1
  mergeDelta = absurd1

data Void1 a

absurd1 :: Void1 a -> b
absurd1 = \case {}

instance Functor Void1 where
  fmap _ = absurd1


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type
data EvaluatedObservable canWait exceptions i = forall c v a. (i ~ c v, IsGeneralizedObservable canWait exceptions c v a) => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions Identity a (EvaluatedObservable canWait exceptions a)

instance IsGeneralizedObservable canWait exceptions Identity a (EvaluatedObservable canWait exceptions a) where
  readObservable# (EvaluatedObservable x) =
    addIdentityWrapper <<$>> readObservable# x
  attachStateObserver# (EvaluatedObservable x) callback =
    addIdentityWrapper <<$>> attachStateObserver# x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateClear -> ObservableChangeWithStateClear
        ObservableChangeWithState waiting NoChangeOperation state ->
          ObservableChangeWithState waiting NoChangeOperation (Identity <$> state)
        ObservableChangeWithState waiting _op state ->
          ObservableChangeWithState waiting (ReplaceOperation (Identity <$> state)) (Identity <$> state)

-- Helper for EvaluatedObservable. Can't use fmap since that maps the container
-- elements.
addIdentityWrapper
  :: WaitingWithState canRetry exceptions c a
  -> WaitingWithState canRetry exceptions Identity (c a)
addIdentityWrapper (WaitingWithState mstate) = WaitingWithState (Identity <<$>> mstate)
addIdentityWrapper (NotWaitingWithState state) = NotWaitingWithState (Identity <$> state)


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


-- ** Observable

type Observable :: CanWait -> [Type] -> Type -> Type
newtype Observable canWait exceptions a = Observable (GeneralizedObservable canWait exceptions Identity a)
type ToObservable :: CanWait -> [Type] -> Type -> Type -> Constraint
type ToObservable canWait exceptions a = ToGeneralizedObservable canWait exceptions Identity a
type IsObservable :: CanWait -> [Type] -> Type -> Type -> Constraint
type IsObservable canWait exceptions a = IsGeneralizedObservable canWait exceptions Identity a

instance Functor (Observable canWait exceptions) where
  fmap fn (Observable x) = Observable (fn <$> x)

instance ToGeneralizedObservable canWait exceptions Identity v (Observable canWait exceptions v) where
  toGeneralizedObservable (Observable x) = x

instance Applicative (Observable canWait exceptions) where
  pure x = Observable (ConstObservable (NotWaitingWithState (Right (Identity x))))
  liftA2 = undefined

instance Monad (Observable canWait exceptions) where
  (>>=) = undefined

toObservable :: ToObservable canWait exceptions v a => a -> Observable canWait exceptions v
toObservable x = Observable (toGeneralizedObservable x)





-- * Some

data Some c = forall a. c a => Some a
