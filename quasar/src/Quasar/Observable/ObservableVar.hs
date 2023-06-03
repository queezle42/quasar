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


data ObservableVar canLoad c v = ObservableVar (TVar (ObservableState canLoad c v)) (CallbackRegistry (ObservableChange canLoad c v))

instance ObservableContainer c v => IsObservableCore canLoad c v (ObservableVar canLoad c v) where
  attachObserver# (ObservableVar var registry) callback = do
    disposer <- registerCallback registry (callback False)
    value <- readTVar var
    pure (disposer, False, value)

  readObservable# (ObservableVar var _registry) =
    (\case ObservableStateLive state -> (False, state)) <$> readTVar var


newObservableVar :: MonadSTMc NoRetry '[] m => c v -> m (ObservableVar canLoad c v)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar (ObservableStateLive x) <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => c v -> m (ObservableVar canLoad c v)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO (ObservableStateLive x) <*> newCallbackRegistryIO

writeObservableVar :: (ObservableContainer c v, MonadSTMc NoRetry '[] m) => ObservableVar canLoad c v -> c v -> m ()
writeObservableVar (ObservableVar var registry) value = liftSTMc $ do
  writeTVar var (ObservableStateLive value)
  callCallbacks registry (ObservableChangeLiveDelta (toInitialDelta value))

readObservableVar
  :: MonadSTMc NoRetry '[] m
  => ObservableVar NoLoad c v
  -> m (c v)
readObservableVar (ObservableVar var _) = liftSTMc @NoRetry @'[] do
  readTVar var >>= \case
    ObservableStateLive result -> pure result

modifyObservableVar :: (MonadSTMc NoRetry '[] m, ObservableContainer c v) => ObservableVar NoLoad c v -> (c v -> c v) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar
  :: (MonadSTMc NoRetry '[] m, ObservableContainer c v)
  => ObservableVar NoLoad c v
  -> (c v -> (a, c v))
  -> m a
stateObservableVar var f = liftSTMc @NoRetry @'[] do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  writeObservableVar var newValue
  pure result

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar canLoad c v -> m Bool
observableVarHasObservers (ObservableVar _ registry) =
  callbackRegistryHasCallbacks registry
