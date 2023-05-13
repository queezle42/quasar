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
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix

-- * Generalized observables

type ToGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class ObservableContainer delta value => ToGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  toGeneralizedObservable :: a -> GeneralizedObservable canWait exceptions delta value
  default toGeneralizedObservable :: IsGeneralizedObservable canWait exceptions delta value a => a -> GeneralizedObservable canWait exceptions delta value
  toGeneralizedObservable = GeneralizedObservable

type IsGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class ToGeneralizedObservable canWait exceptions delta value a => IsGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  {-# MINIMAL readObservable#, (attachObserver# | attachStateObserver#) #-}
  readObservable# :: a -> STMc NoRetry '[] (Final, ObservableState canWait exceptions value)

  attachObserver# :: a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachObserver# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateWaiting _ -> ObservableChangeWaiting
      ObservableChangeWithStateUpdate delta _ -> ObservableChangeUpdate delta

  attachStateObserver# :: a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
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

  mapObservable# :: (value -> n) -> a -> Observable canWait exceptions n
  mapObservable# f (evaluateObservable# -> Some x) = Observable (GeneralizedObservable (MappedObservable f x))

  mapObservableDelta# :: ObservableContainer newDelta newValue => (delta -> newDelta) -> (value -> newValue) -> a -> GeneralizedObservable canWait exceptions newDelta newValue
  mapObservableDelta# fd fn x = GeneralizedObservable (DeltaMappedObservable fd fn x)

readObservable
  :: (ToGeneralizedObservable NoWait exceptions delta value a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m value
readObservable x = case toGeneralizedObservable x of
  (ConstObservable state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => ObservableState NoWait exceptions a -> m a
    extractState (ObservableStateValue z) = either throwEx pure z

attachObserver :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachStateObserver :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachStateObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachStateObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Bool
isCachedObservable x = case toGeneralizedObservable x of
  GeneralizedObservable notConst -> isCachedObservable# notConst
  ConstObservable _value -> True

mapObservable :: ToGeneralizedObservable canWait exceptions delta value a => (value -> f) -> a -> Observable canWait exceptions f
mapObservable fn x = case toGeneralizedObservable x of
  (GeneralizedObservable x) -> mapObservable# fn x
  (ConstObservable state) -> Observable (ConstObservable (fn <$> state))

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

type ObservableChangeWithState :: CanWait -> [Type] -> Type -> Type -> Type
data ObservableChangeWithState canWait exceptions delta value where
  ObservableChangeWithStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableChangeWithState Wait exceptions delta value
  ObservableChangeWithStateUpdate :: Maybe (Either (Ex exceptions) delta) -> Either (Ex exceptions) value -> ObservableChangeWithState canWait exceptions delta value

instance Functor (ObservableChange canWait exceptions) where
  fmap _ ObservableChangeWaiting = ObservableChangeWaiting
  fmap fn (ObservableChangeUpdate x) = ObservableChangeUpdate (fn <<$>> x)

instance Functor (ObservableState canWait exceptions) where
  fmap fn (ObservableStateWaiting x) = ObservableStateWaiting (fn <<$>> x)
  fmap fn (ObservableStateValue x) = ObservableStateValue (fn <$> x)

applyObservableChange :: ObservableContainer delta value => ObservableChange canWait exceptions delta -> ObservableState canWait exceptions value -> ObservableChangeWithState canWait exceptions delta value
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

changeWithStateToState :: ObservableChangeWithState canWait exceptions delta value -> ObservableState canWait exceptions value
changeWithStateToState (ObservableChangeWithStateWaiting cached) = ObservableStateWaiting cached
changeWithStateToState (ObservableChangeWithStateUpdate _delta value) = ObservableStateValue value


type GeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data GeneralizedObservable canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => GeneralizedObservable a
  | ConstObservable (ObservableState canWait exceptions value)

instance ObservableContainer delta value => ToGeneralizedObservable canWait exceptions delta value (GeneralizedObservable canWait exceptions delta value) where
  toGeneralizedObservable = id

class ObservableContainer delta value where
  applyDelta :: delta -> Maybe value -> value
  mergeDelta :: delta -> delta -> delta

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions delta value a => a -> Some (IsObservable canWait exceptions value)
  evaluateObservable# x = Some (EvaluatedObservable x)

  toObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Observable canWait exceptions value
  toObservable x = Observable
    case toGeneralizedObservable x of
      (GeneralizedObservable f) -> GeneralizedObservable (EvaluatedObservable f)
      (ConstObservable c) -> ConstObservable c

instance ObservableContainer a a where
  applyDelta new _ = new
  mergeDelta _ new = new
  evaluateObservable# x = Some x
  toObservable x = Observable (toGeneralizedObservable x)


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data EvaluatedObservable canWait exceptions delta value = forall a. IsGeneralizedObservable canWait exceptions delta value a => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value)

instance IsGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value) where
  readObservable# (EvaluatedObservable x) = readObservable# x
  attachStateObserver# (EvaluatedObservable x) callback =
    attachStateObserver# x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateWaiting cache -> ObservableChangeWithStateWaiting cache
        -- Replace delta with evaluated value
        ObservableChangeWithStateUpdate _delta content -> ObservableChangeWithStateUpdate (Just content) content


data DeltaMappedObservable canWait exceptions delta value = forall oldDelta oldValue a. IsGeneralizedObservable canWait exceptions oldDelta oldValue a => DeltaMappedObservable (oldDelta -> delta) (oldValue -> value) a

instance ObservableContainer delta value => ToGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value)

instance ObservableContainer delta value => IsGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value) where
  attachObserver# (DeltaMappedObservable deltaFn valueFn observable) callback =
    fmap3 valueFn $ attachObserver# observable \final change ->
      callback final (deltaFn <$> change)
  readObservable# (DeltaMappedObservable _deltaFn valueFn observable) =
    fmap3 valueFn $ readObservable# observable
  mapObservableDelta# fd1 fn1 (DeltaMappedObservable fd2 fn2 x) = GeneralizedObservable (DeltaMappedObservable (fd1 . fd2) (fn1 . fn2) x)


-- ** Observable

type Observable :: CanWait -> [Type] -> Type -> Type
newtype Observable canWait exceptions a = Observable (GeneralizedObservable canWait exceptions a a)
type ToObservable canWait exceptions a = ToGeneralizedObservable canWait exceptions a a
type IsObservable canWait exceptions a = IsGeneralizedObservable canWait exceptions a a

instance ToGeneralizedObservable canWait exceptions value value (Observable canWait exceptions value) where
  toGeneralizedObservable (Observable x) = x

instance Functor (Observable canWait exceptions) where
  fmap f (Observable x) = mapObservable f x

instance Applicative (Observable canWait exceptions) where
  pure value = Observable (ConstObservable (ObservableStateValue (Right value)))
  liftA2 = undefined

instance Monad (Observable canWait exceptions) where
  (>>=) = undefined


data MappedObservable canWait exceptions value = forall prev a. IsObservable canWait exceptions prev a => MappedObservable (prev -> value) a

instance ToGeneralizedObservable canWait exceptions value value (MappedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions value value (MappedObservable canWait exceptions value) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


-- * Some

data Some c = forall a. c a => Some a
