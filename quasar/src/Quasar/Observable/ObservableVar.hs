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


data ObservableVar canLoad exceptions c v = ObservableVar (TVar (ObservableState canLoad exceptions c v)) (CallbackRegistry (ObservableChange canLoad exceptions c v))

instance ObservableContainer c v => ToObservable canLoad exceptions c v (ObservableVar canLoad exceptions c v)

instance ObservableContainer c v => IsObservable canLoad exceptions c v (ObservableVar canLoad exceptions c v) where
  attachObserver# (ObservableVar var registry) callback = do
    disposer <- registerCallback registry (callback False)
    value <- readTVar var
    pure (disposer, False, value)

  readObservable# (ObservableVar var _registry) = (False,) <$> readTVar var

newObservableVar :: MonadSTMc NoRetry '[] m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar (ObservableStateLive (Right x)) <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO (ObservableStateLive (Right x)) <*> newCallbackRegistryIO

writeObservableVar :: (ObservableContainer c v, MonadSTMc NoRetry '[] m) => ObservableVar canLoad exceptions c v -> c v -> m ()
writeObservableVar (ObservableVar var registry) value = liftSTMc $ do
  writeTVar var (ObservableStateLive (Right value))
  callCallbacks registry (ObservableChangeLiveDelta (toInitialDelta value))

readObservableVar
  :: forall exceptions c v m. MonadSTMc NoRetry exceptions m
  => ObservableVar NoLoad exceptions c v
  -> m (c v)
readObservableVar (ObservableVar var _) = liftSTMc @NoRetry @exceptions do
  readTVar var >>= \case
    ObservableStateLive (Left ex) -> throwEx ex
    ObservableStateLive (Right result) -> pure result

modifyObservableVar :: (MonadSTMc NoRetry exceptions m, ObservableContainer c v) => ObservableVar NoLoad exceptions c v -> (c v -> c v) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar
  :: forall exceptions c v m a. (MonadSTMc NoRetry exceptions m, ObservableContainer c v)
  => ObservableVar NoLoad exceptions c v
  -> (c v -> (a, c v))
  -> m a
stateObservableVar var f = liftSTMc @NoRetry @exceptions do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  writeObservableVar var newValue
  pure result

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar canLoad exceptions c v -> m Bool
observableVarHasObservers (ObservableVar _ registry) =
  callbackRegistryHasCallbacks registry
