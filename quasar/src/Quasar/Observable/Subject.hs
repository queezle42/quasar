{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Subject (
  Subject,
  newSubject,
  newSubjectIO,
  newLoadingSubject,
  newLoadingSubjectIO,
  newFailedSubject,
  newFailedSubjectIO,
  replaceSubject,
  clearSubject,
  failSubject,
  readSubject,
  readSubjectIO,
  changeSubject,
  updateSimpleSubject,
  subjectHasObservers,
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Core


data Subject canLoad exceptions c v = Subject (TVar (ObserverState canLoad (ObservableResult exceptions c) v)) (CallbackRegistry (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v))

instance (ContainerConstraint canLoad exceptions c v (Subject canLoad exceptions c v), ObservableContainer c v) => ToObservableT canLoad exceptions c v (Subject canLoad exceptions c v) where
  toObservableT var = ObservableT var

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (Subject canLoad exceptions c v) where
  attachEvaluatedObserver# (Subject var registry) callback = do
    readTVar var >>= \case
      ObserverStateLoadingCleared -> do
        disposer <- registerCallback registry callback
        pure (disposer, ObservableStateLoading)
      ObserverStateLoadingCached cache -> do
        disposer <- registerCallback registry (callback . fixInvalidCacheState cache)
        pure (disposer, ObservableStateLoading)
      ObserverStateLive result -> do
        disposer <- registerCallback registry callback
        pure (disposer, ObservableStateLive result)

  readObservable# (Subject var _registry) = toObservableState <$> readTVar var


-- Precondition: Observer is in `ObserverStateLoadingCleared` state, but caller
-- assumes the observer is in `ObserverStateLoadingCached` state.
fixInvalidCacheState ::
  (ObservableContainer c v) =>
  ObservableResult exceptions c v ->
  EvaluatedObservableChange Load (ObservableResult exceptions c) v ->
  EvaluatedObservableChange Load (ObservableResult exceptions c) v
fixInvalidCacheState _cached EvaluatedObservableChangeLoadingClear =
  EvaluatedObservableChangeLoadingClear
fixInvalidCacheState cached EvaluatedObservableChangeLiveUnchanged =
  EvaluatedObservableChangeLiveReplace cached
fixInvalidCacheState _cached replace@(EvaluatedObservableChangeLiveReplace _) =
  replace
fixInvalidCacheState _cached (EvaluatedObservableChangeLiveDelta delta) =
  EvaluatedObservableChangeLiveReplace (contentFromEvaluatedDelta delta)
fixInvalidCacheState _cached EvaluatedObservableChangeLoadingUnchanged =
  -- Filtered by `applyObservableChange` in `changeSubject`
  unreachableCodePath


newSubject :: MonadSTMc NoRetry '[] m => c v -> m (Subject canLoad exceptions c v)
newSubject x = liftSTMc $
  Subject <$> newTVar (ObserverStateLiveOk x) <*> newCallbackRegistry

newLoadingSubject :: forall exceptions c v m. MonadSTMc NoRetry '[] m => m (Subject Load exceptions c v)
newLoadingSubject = liftSTMc $
  Subject <$> newTVar (ObserverStateLoadingCleared @(ObservableResult exceptions c) @v) <*> newCallbackRegistry

newFailedSubject ::
  (MonadSTMc NoRetry '[] m, Exception e, e :< exceptions) =>
  e -> m (Subject canLoad exceptions c v)
newFailedSubject exception = liftSTMc $
  Subject <$> newTVar (ObserverStateLiveEx (toEx exception)) <*> newCallbackRegistry

newSubjectIO :: MonadIO m => c v -> m (Subject canLoad exceptions c v)
newSubjectIO x = liftIO $
  Subject <$> newTVarIO (ObserverStateLiveOk x) <*> newCallbackRegistryIO

newLoadingSubjectIO :: forall exceptions c v m. MonadIO m => m (Subject Load exceptions c v)
newLoadingSubjectIO = liftIO $
  Subject <$> newTVarIO (ObserverStateLoadingCleared @(ObservableResult exceptions c) @v) <*> newCallbackRegistryIO

newFailedSubjectIO :: (MonadIO m, Exception e, e :< exceptions) => e -> m (Subject canLoad exceptions c v)
newFailedSubjectIO exception = liftIO $
  Subject <$> newTVarIO (ObserverStateLiveEx (toEx exception)) <*> newCallbackRegistryIO

changeSubject
  :: (MonadSTMc NoRetry '[] m, ObservableContainer c v)
  => Subject canLoad exceptions c v
  -> ObservableChange canLoad (ObservableResult exceptions c) v
  -> m ()
changeSubject (Subject var registry) change = liftSTMc do
  state <- readTVar var
  forM_ (applyObservableChange change state) \(evaluatedChange, newState) -> do
    writeTVar var newState
    callCallbacks registry evaluatedChange

updateSimpleSubject ::
  forall c v m.
  (MonadSTMc NoRetry '[] m, ObservableContainer c v) =>
  Subject NoLoad '[] c v ->
  (c v -> Maybe (ObservableUpdate c v)) ->
  m ()
updateSimpleSubject (Subject var registry) mkUpdate = liftSTMc do
  state <- readTVar var
  let (ObserverStateLive (ObservableResultTrivial content)) = state
  forM_ (observableUpdateToChange (ObserverContextLive (toDeltaContext @c content)) (mkUpdate content)) \containerChange -> do
    let change = mapObservableChange ObservableResultOk id containerChange
    forM_ (applyObservableChange change state) \(evaluatedChange, newState) -> do
      writeTVar var newState
      callCallbacks registry evaluatedChange

-- | Replace the subjects content.
--
-- Should not be used if it is possible to send deltas (partial updates) instead
-- (see `changeSubject`).
replaceSubject :: (MonadSTMc NoRetry '[] m) => Subject canLoad exceptions c v -> c v -> m ()
replaceSubject (Subject var registry) value = liftSTMc $ do
  writeTVar var (ObserverStateLiveOk value)
  callCallbacks registry (EvaluatedObservableChangeLiveReplace (ObservableResultOk value))

-- | Set the subjects state to @Loading@.
clearSubject :: (MonadSTMc NoRetry '[] m) => Subject Load exceptions c v -> m ()
clearSubject (Subject var registry) = liftSTMc $ do
  readTVar var >>= \case
    ObserverStateLoadingCleared -> pure ()
    _ -> do
      writeTVar var ObserverStateLoadingCleared
      callCallbacks registry EvaluatedObservableChangeLoadingClear

-- | Replace the subjects state with an exception.
failSubject :: (MonadSTMc NoRetry '[] m, Exception e, e :< exceptions) => Subject canLoad exceptions c v -> e -> m ()
failSubject (Subject var registry) exception = liftSTMc $ do
  let ex = toEx exception
  writeTVar var (ObserverStateLiveEx ex)
  callCallbacks registry (EvaluatedObservableChangeLiveReplace (ObservableResultEx ex))


readSubject
  :: MonadSTMc NoRetry '[] m
  => Subject NoLoad '[] c v
  -> m (c v)
readSubject (Subject var _) = liftSTMc @NoRetry @'[] do
  readTVar var >>= \case
    ObserverStateLive (ObservableResultTrivial result) -> pure result

readSubjectIO
  :: MonadIO m
  => Subject NoLoad '[] c v
  -> m (c v)
readSubjectIO (Subject var _) = liftIO do
  readTVarIO var >>= \case
    ObserverStateLiveOk result -> pure result
    ObserverStateLiveEx ex -> absurdEx ex

subjectHasObservers :: MonadSTMc NoRetry '[] m => Subject canLoad exceptions c v -> m Bool
subjectHasObservers (Subject _ registry) =
  callbackRegistryHasCallbacks registry
