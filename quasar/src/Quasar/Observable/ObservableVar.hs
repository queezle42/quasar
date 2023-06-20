module Quasar.Observable.ObservableVar (
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  newLoadingObservableVar,
  newLoadingObservableVarIO,
  writeObservableVar,
  readObservableVar,
  modifyObservableVar,
  stateObservableVar,
  changeObservableVar,
  observableVarHasObservers,
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Core


data ObservableVar canLoad exceptions c v = ObservableVar (TVar (ObserverState canLoad (ObservableResult exceptions c) v)) (CallbackRegistry (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v))

instance ObservableContainer c v => ToObservable canLoad exceptions c v (ObservableVar canLoad exceptions c v) where
  toObservable var = Observable var

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (ObservableVar canLoad exceptions c v) where
  attachEvaluatedObserver# (ObservableVar var registry) callback = do
    disposer <- registerCallback registry callback
    value <- readTVar var
    pure (disposer, toObservableState value)

  readObservable# (ObservableVar var _registry) =
    (\case ObserverStateLive state -> state) <$> readTVar var


newObservableVar :: MonadSTMc NoRetry '[] m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar (ObserverStateLiveOk x) <*> newCallbackRegistry

newLoadingObservableVar :: forall exceptions c v m. MonadSTMc NoRetry '[] m => m (ObservableVar Load exceptions c v)
newLoadingObservableVar = liftSTMc $ ObservableVar <$> newTVar (ObserverStateLoadingCleared @(ObservableResult exceptions c) @v) <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => c v -> m (ObservableVar canLoad exceptions c v)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO (ObserverStateLiveOk x) <*> newCallbackRegistryIO

newLoadingObservableVarIO :: forall exceptions c v m. MonadIO m => m (ObservableVar Load exceptions c v)
newLoadingObservableVarIO = liftIO $ ObservableVar <$> newTVarIO (ObserverStateLoadingCleared @(ObservableResult exceptions c) @v) <*> newCallbackRegistryIO

writeObservableVar :: (ObservableContainer c v, MonadSTMc NoRetry '[] m) => ObservableVar canLoad exceptions c v -> c v -> m ()
writeObservableVar (ObservableVar var registry) value = liftSTMc $ do
  writeTVar var (ObserverStateLiveOk value)
  callCallbacks registry (EvaluatedObservableChangeLiveDeltaOk (toInitialEvaluatedDelta value))

readObservableVar
  :: MonadSTMc NoRetry '[] m
  => ObservableVar NoLoad '[] c v
  -> m (c v)
readObservableVar (ObservableVar var _) = liftSTMc @NoRetry @'[] do
  readTVar var >>= \case
    ObserverStateLiveOk result -> pure result
    ObserverStateLiveEx ex -> absurdEx ex

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

changeObservableVar
  :: (MonadSTMc NoRetry '[] m, ObservableContainer c v)
  => ObservableVar canLoad exceptions c v
  -> ObservableChange canLoad (ObservableResult exceptions c) v
  -> m ()
changeObservableVar (ObservableVar var registry) change = liftSTMc do
  state <- readTVar var
  forM_ (applyObservableChange change state) \(evaluatedChange, newState) -> do
    writeTVar var newState
    callCallbacks registry evaluatedChange

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar canLoad exceptions c v -> m Bool
observableVarHasObservers (ObservableVar _ registry) =
  callbackRegistryHasCallbacks registry
