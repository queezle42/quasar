module Quasar.Observable.AccumulatingObserver (
  AccumulatingObserver,
  attachAccumulatingObserver,
  takeAccumulatingObserver,
  disposeAccumulatingObserver,
) where

import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources
import Quasar.Utils.Fix (mfixTVar)

data AccumulatingObserver canLoad exceptions c v =
  AccumulatingObserver
    TDisposer
    (TVar (Maybe (PendingChange canLoad (ObservableResult exceptions c) v)))
    (TVar (LastChange canLoad))

instance Disposable (AccumulatingObserver canLoad exceptions c v) where
  getDisposer (AccumulatingObserver disposer _ _) = getDisposer disposer

attachAccumulatingObserver ::
  ObservableContainer c v =>
  ObservableT canLoad exceptions c v ->
  STMc NoRetry '[] (
    Maybe (AccumulatingObserver canLoad exceptions c v),
    ObservableState canLoad (ObservableResult exceptions c) v
  )
attachAccumulatingObserver observable = do
  mfixTVar \pendingVar -> do
    mfixTVar \lastVar -> do
      (obsDisposer, initial) <- attachObserver# observable \change -> do
        readTVar pendingVar >>= mapM_ \oldPending ->
          writeTVar pendingVar (Just (updatePendingChange change oldPending))

      let (pending, last) = initialPendingAndLastChange initial

      if isTrivialTDisposer obsDisposer
        then pure (((Nothing, initial), Just pending), last)
        else do
          accumDisposer <- newUnmanagedTDisposer do
            writeTVar pendingVar Nothing

          let disposer = accumDisposer <> obsDisposer

          pure (((Just (AccumulatingObserver disposer pendingVar lastVar), initial), Just pending), last)

takeAccumulatingObserver ::
  ObservableContainer c v =>
  AccumulatingObserver canLoad exceptions c v ->
  Loading canLoad ->
  STMc NoRetry '[] (Maybe (ObservableChange canLoad (ObservableResult exceptions c) v))
takeAccumulatingObserver (AccumulatingObserver _ pendingVar lastVar) loading = do
  readTVar pendingVar >>= \case
    Nothing -> pure Nothing
    Just pending -> do
      last <- readTVar lastVar
      case changeFromPending loading pending last of
        Nothing -> pure Nothing
        Just (change, newPending, newLast) -> do
          writeTVar pendingVar (Just newPending)
          writeTVar lastVar newLast
          pure (Just change)

disposeAccumulatingObserver ::
  AccumulatingObserver canLoad exceptions c v ->
  STMc NoRetry '[] ()
disposeAccumulatingObserver (AccumulatingObserver disposer _ _) =
  disposeTDisposer disposer
