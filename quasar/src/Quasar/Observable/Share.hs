{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Share (
  -- TODO move to Observable module
  shareObservable,
  observeSharedObservable,

  shareObservableT,

  -- ** Observable operation type
  SharedObservable,
) where

import Control.Applicative
import Data.Functor.Identity
import Quasar.Disposer
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Utils.CallbackRegistry

-- * Share

newtype SharedObservable canLoad exceptions c v = SharedObservable (TVar (ShareState canLoad exceptions c v))

data ShareState canLoad exceptions c v
  = forall a. IsObservableCore canLoad exceptions c v a => ShareIdle a
  | forall a. IsObservableCore canLoad exceptions c v a
    => ShareAttached
      a
      TDisposer
      (CallbackRegistry (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v))
      (ObserverState canLoad (ObservableResult exceptions c) v)

instance (ObservableContainer c v, ContainerConstraint canLoad exceptions c v (SharedObservable canLoad exceptions c v)) => ToObservableT canLoad exceptions c v (SharedObservable canLoad exceptions c v) where
  toObservableT = ObservableT

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (SharedObservable canLoad exceptions c v) where
  readObservable# (SharedObservable var) = do
    readTVar var >>= \case
      ShareIdle x -> readObservable# x
      ShareAttached _x _disposer _registry state -> pure (toObservableState state)

  attachEvaluatedObserver# (SharedObservable var) callback = do
    readTVar var >>= \case
      ShareIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeShareListener
        (upstreamDisposer, state) <- attachEvaluatedObserver# upstream updateShare
        writeTVar var (ShareAttached upstream upstreamDisposer registry (createObserverState state))
        disposer <- registerCallback registry callback
        pure (disposer, state)
      ShareAttached _ _ registry state -> do
        case state of
          -- The shared state can't be propagated downstream, so the first
          -- callback invocation must not send a Delta or a LiveUnchanged.
          -- The callback is wrapped to change them to a Replace.
          ObserverStateLoadingCached cache -> do
            disposer <- registerCallbackChangeAfterFirstCall registry (callback . fixInvalidShareState cache) callback
            pure (disposer, ObservableStateLoading)
          _ -> do
            disposer <- registerCallback registry callback
            pure (disposer, toObservableState state)
    where
      removeShareListener :: STMc NoRetry '[] ()
      removeShareListener = do
        readTVar var >>= \case
          ShareIdle _ -> unreachableCodePath
          ShareAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (ShareIdle upstream)
            disposeTDisposer upstreamDisposer
      updateShare :: EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()
      updateShare change = do
        readTVar var >>= \case
          ShareIdle _ -> unreachableCodePath
          ShareAttached upstream upstreamDisposer registry oldState -> do
            let mstate = applyEvaluatedObservableChange change oldState
            forM_ mstate \state -> do
              writeTVar var (ShareAttached upstream upstreamDisposer registry state)
              callCallbacks registry change

  isSharedObservable# _ = True

-- Precondition: Observer is in `ObserverStateLoadingCleared` state, but caller
-- assumes the observer is in `ObserverStateLoadingShared` state.
fixInvalidShareState ::
  ObservableResult exceptions c v ->
  EvaluatedObservableChange Load (ObservableResult exceptions c) v ->
  EvaluatedObservableChange Load (ObservableResult exceptions c) v
fixInvalidShareState _shared EvaluatedObservableChangeLoadingClear =
  EvaluatedObservableChangeLoadingClear
fixInvalidShareState shared EvaluatedObservableChangeLiveUnchanged =
  EvaluatedObservableChangeLiveReplace shared
fixInvalidShareState _shared replace@(EvaluatedObservableChangeLiveReplace _) =
  replace
fixInvalidShareState _shared (EvaluatedObservableChangeLiveDelta delta) =
  EvaluatedObservableChangeLiveReplace (contentFromEvaluatedDelta delta)
fixInvalidShareState _shared EvaluatedObservableChangeLoadingUnchanged =
  -- Filtered by `applyEvaluatedObservableChange` in `updateShare`
  impossibleCodePath

shareObservable ::
  MonadSTMc NoRetry '[] m =>
  Observable canLoad exceptions v -> m (Observable canLoad exceptions v)
shareObservable (Observable f) = Observable <$> shareObservableT f

shareObservableT ::
  (
    ObservableContainer c v,
    ContainerConstraint canLoad exceptions c v (SharedObservable canLoad exceptions c v),
    MonadSTMc NoRetry '[] m
  ) =>
  ObservableT canLoad exceptions c v -> m (ObservableT canLoad exceptions c v)
shareObservableT f =
  if isSharedObservable# f
    then pure f
    else ObservableT . SharedObservable <$> newTVar (ShareIdle f)


-- ** Embedded share in the Observable monad

newtype ShareObservableOperation canLoad exceptions l e v = ShareObservableOperation (Observable l e v)

instance ToObservableT canLoad exceptions Identity (Observable l e v) (ShareObservableOperation canLoad exceptions l e v) where
  toObservableT = ObservableT

instance IsObservableCore canLoad exceptions Identity (Observable l e v) (ShareObservableOperation canLoad exceptions l e v) where
  readObservable# (ShareObservableOperation x) = do
    share <- shareObservable x
    pure (pure share)
  attachObserver# (ShareObservableOperation x) _callback = do
    share <- shareObservable x
    pure (mempty, ObservableStateLive (pure share))

-- | Share an observable in the `Observable` monad. Use with care! A new share
-- is created for every outer observable evaluation.
observeSharedObservable :: forall canLoad exceptions e l v a. ToObservable l e v a => a -> Observable canLoad exceptions (Observable l e v)
observeSharedObservable x =
  toObservable (ShareObservableOperation @canLoad @exceptions (toObservable x))
