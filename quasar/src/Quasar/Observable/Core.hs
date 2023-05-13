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
  ObservableState(..),
  ObservableChangeWithState(..),
  changeWithStateToState,

  -- * Identity observable (single value without partial updats)
  Observable(..),
  ToObservable,
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
  readObservable# :: a -> STMc NoRetry '[] (Final, ObservableState canWait exceptions value)

  attachObserver# :: a -> (Final -> ObservableChange canWait exceptions (Delta value) -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachObserver# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateWaiting _ -> ObservableChangeWaiting
      ObservableChangeWithStateUpdate delta _ -> ObservableChangeUpdate delta

  attachStateObserver# :: a -> (Final -> ObservableChangeWithState canWait exceptions value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachStateObserver# x callback =
    mfixTVar \var -> do
      (disposer, final, initial) <- attachObserver# x \final change -> do
        merged <- stateTVar var \oldState ->
          let merged = applyObservableChange change oldState
          in (merged, changeWithStateToState merged)
        callback final merged
      pure ((disposer, final, initial), initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: value ~ Identity prev => (prev -> next) -> a -> Observable canWait exceptions next
  mapObservable# f x = Observable (GeneralizedObservable (MappedObservable f x))

  mapObservableDelta# :: ObservableContainer newValue => (Delta value -> Delta newValue) -> (value -> newValue) -> a -> GeneralizedObservable canWait exceptions newValue
  mapObservableDelta# fd fn x = GeneralizedObservable (DeltaMappedObservable fd fn x)

readObservable
  :: (ToGeneralizedObservable NoWait exceptions value a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m value
readObservable x = case toGeneralizedObservable x of
  (ConstObservable state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => ObservableState NoWait exceptions a -> m a
    extractState (ObservableStateValue z) = either throwEx pure z

attachObserver :: (ToGeneralizedObservable canWait exceptions value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions (Delta value) -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachStateObserver :: (ToGeneralizedObservable canWait exceptions value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
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

type ObservableChange :: CanWait -> [Type] -> Type -> Type
data ObservableChange canWait exceptions delta where
  ObservableChangeWaiting :: ObservableChange Wait exceptions delta
  ObservableChangeUpdate :: Maybe (Either (Ex exceptions) delta) -> ObservableChange canWait exceptions delta

type ObservableState :: CanWait -> [Type] -> Type -> Type
data ObservableState canWait exceptions value where
  ObservableStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableState Wait exceptions value
  ObservableStateValue :: Either (Ex exceptions) value -> ObservableState canWait exceptions value

type ObservableChangeWithState :: CanWait -> [Type] -> Type -> Type
data ObservableChangeWithState canWait exceptions value where
  ObservableChangeWithStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableChangeWithState Wait exceptions value
  ObservableChangeWithStateUpdate :: Maybe (Either (Ex exceptions) (Delta value)) -> Either (Ex exceptions) value -> ObservableChangeWithState canWait exceptions value

instance Functor (ObservableChange canWait exceptions) where
  fmap _ ObservableChangeWaiting = ObservableChangeWaiting
  fmap fn (ObservableChangeUpdate x) = ObservableChangeUpdate (fn <<$>> x)

instance Functor (ObservableState canWait exceptions) where
  fmap fn (ObservableStateWaiting x) = ObservableStateWaiting (fn <<$>> x)
  fmap fn (ObservableStateValue x) = ObservableStateValue (fn <$> x)

applyObservableChange :: ObservableContainer value => ObservableChange canWait exceptions (Delta value) -> ObservableState canWait exceptions value -> ObservableChangeWithState canWait exceptions value
-- Set to loading
applyObservableChange ObservableChangeWaiting (ObservableStateValue x) = ObservableChangeWithStateWaiting (Just x)
applyObservableChange ObservableChangeWaiting (ObservableStateWaiting x) = ObservableChangeWithStateWaiting x
-- Reactivate old value
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateWaiting (Just x)) = ObservableChangeWithStateUpdate Nothing x
-- NOTE: An update is ignored for uncached waiting state.
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateWaiting Nothing) = ObservableChangeWithStateWaiting Nothing
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateValue x) = ObservableChangeWithStateUpdate Nothing x
-- Update with exception delta
applyObservableChange (ObservableChangeUpdate delta@(Just (Left x))) _ = ObservableChangeWithStateUpdate delta (Left x)
-- Update with value delta
applyObservableChange (ObservableChangeUpdate delta@(Just (Right x))) y =
  ObservableChangeWithStateUpdate delta (Right (applyDelta x (getStateValue y)))
  where
    getStateValue :: ObservableState canWait exceptions a -> Maybe a
    getStateValue (ObservableStateWaiting (Just (Right value))) = Just value
    getStateValue (ObservableStateValue (Right value)) = Just value
    getStateValue _ = Nothing

changeWithStateToState :: ObservableChangeWithState canWait exceptions value -> ObservableState canWait exceptions value
changeWithStateToState (ObservableChangeWithStateWaiting cached) = ObservableStateWaiting cached
changeWithStateToState (ObservableChangeWithStateUpdate _delta value) = ObservableStateValue value


type GeneralizedObservable :: CanWait -> [Type] -> Type -> Type
data GeneralizedObservable canWait exceptions value
  = forall a. IsGeneralizedObservable canWait exceptions value a => GeneralizedObservable a
  | ConstObservable (ObservableState canWait exceptions value)

instance ObservableContainer value => ToGeneralizedObservable canWait exceptions value (GeneralizedObservable canWait exceptions value) where
  toGeneralizedObservable = id

class ObservableContainer value where
  type Delta value
  applyDelta :: Delta value -> Maybe value -> value
  mergeDelta :: Delta value -> Delta value -> Delta value

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions value a => a -> Some (IsObservable canWait exceptions value)
  evaluateObservable# x = Some (EvaluatedObservable x)

  --toObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Observable canWait exceptions value
  --toObservable x = Observable
  --  case toGeneralizedObservable x of
  --    (GeneralizedObservable f) -> GeneralizedObservable (EvaluatedObservable f)
  --    (ConstObservable c) -> ConstObservable c

instance ObservableContainer (Identity a) where
  type Delta (Identity a) = a
  applyDelta new _ = Identity new
  mergeDelta _ new = new
  --toObservable x = Observable (toGeneralizedObservable x)


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type
data EvaluatedObservable canWait exceptions value = forall a. IsGeneralizedObservable canWait exceptions value a => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions (Identity value) (EvaluatedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions (Identity value) (EvaluatedObservable canWait exceptions value) where
  readObservable# (EvaluatedObservable x) = fmap3 Identity $ readObservable# x
  attachStateObserver# (EvaluatedObservable @a x) callback =
    fmap3 Identity $ attachStateObserver# @a x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateWaiting cache -> ObservableChangeWithStateWaiting (Identity <<$>> cache)
        -- Replace delta with evaluated value
        ObservableChangeWithStateUpdate _delta content -> ObservableChangeWithStateUpdate (Just content) (Identity <$> content)


data DeltaMappedObservable canWait exceptions value = forall oldValue a. IsGeneralizedObservable canWait exceptions oldValue a => DeltaMappedObservable (Delta oldValue -> Delta value) (oldValue -> value) a

instance ObservableContainer value => ToGeneralizedObservable canWait exceptions value (DeltaMappedObservable canWait exceptions value)

instance ObservableContainer value => IsGeneralizedObservable canWait exceptions value (DeltaMappedObservable canWait exceptions value) where
  attachObserver# (DeltaMappedObservable deltaFn valueFn observable) callback =
    fmap3 valueFn $ attachObserver# observable \final change ->
      callback final (deltaFn <$> change)
  readObservable# (DeltaMappedObservable _deltaFn valueFn observable) =
    fmap3 valueFn $ readObservable# observable
  mapObservableDelta# fd1 fn1 (DeltaMappedObservable fd2 fn2 x) = GeneralizedObservable (DeltaMappedObservable (fd1 . fd2) (fn1 . fn2) x)


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
  pure value = Observable (ConstObservable (ObservableStateValue (Right (Identity value))))
  liftA2 = undefined

instance Monad (Observable canWait exceptions) where
  (>>=) = undefined


data MappedObservable canWait exceptions value = forall prev a. IsObservable canWait exceptions prev a => MappedObservable (prev -> value) a

instance ToGeneralizedObservable canWait exceptions (Identity value) (MappedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions (Identity value) (MappedObservable canWait exceptions value) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap4 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap4 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


-- * Some

data Some c = forall a. c a => Some a
