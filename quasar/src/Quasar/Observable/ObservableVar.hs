module Quasar.Observable.ObservableVar (
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  writeObservableVar,
  readObservableVar,
  modifyObservableVar,
  stateObservableVar,
  observableVarHasObservers,
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Core


data ObservableVar canLoad exceptions c v = ObservableVar (TVar (ObservableState canLoad (ObservableResult exceptions c) v)) (CallbackRegistry (ObservableChange canLoad (ObservableResult exceptions c) v))

instance ObservableContainer c v => ToObservable canLoad exceptions c v (ObservableVar canLoad exceptions c v) where
  toObservable = DynObservable

instance ObservableContainer c v => IsObservableCore canLoad (ObservableResult exceptions c) v (ObservableVar canLoad exceptions c v) where
  attachObserver# (ObservableVar var registry) callback = do
    disposer <- registerCallback registry (callback False)
    value <- readTVar var
    pure (disposer, False, value)

  readObservable# (ObservableVar var _registry) =
    (\case ObservableStateLive state -> (False, state)) <$> readTVar var


newObservableVar :: MonadSTMc NoRetry '[] m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar (ObservableStateLiveOk x) <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO (ObservableStateLiveOk x) <*> newCallbackRegistryIO

writeObservableVar :: (ObservableContainer c v, MonadSTMc NoRetry '[] m) => ObservableVar canLoad exceptions c v -> c v -> m ()
writeObservableVar (ObservableVar var registry) value = liftSTMc $ do
  writeTVar var (ObservableStateLiveOk value)
  callCallbacks registry (ObservableChangeLiveDeltaOk (toInitialDelta value))

readObservableVar
  :: MonadSTMc NoRetry '[] m
  => ObservableVar NoLoad '[] c v
  -> m (c v)
readObservableVar (ObservableVar var _) = liftSTMc @NoRetry @'[] do
  readTVar var >>= \case
    ObservableStateLiveOk result -> pure result
    ObservableStateLiveEx ex -> absurdEx ex

modifyObservableVar :: (MonadSTMc NoRetry '[] m, ObservableContainer c v) => ObservableVar NoLoad '[] c v -> (c v -> c v) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar
  :: (MonadSTMc NoRetry '[] m, ObservableContainer c v)
  => ObservableVar NoLoad '[] c v
  -> (c v -> (a, c v))
  -> m a
stateObservableVar var f = liftSTMc @NoRetry @'[] do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  writeObservableVar var newValue
  pure result

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar canLoad exceptions c v -> m Bool
observableVarHasObservers (ObservableVar _ registry) =
  callbackRegistryHasCallbacks registry
