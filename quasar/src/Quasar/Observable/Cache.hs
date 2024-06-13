{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Cache (
  -- TODO move to Observable module
  cacheObservable,
  observeCachedObservable,

  cacheObservableT,

  -- ** Observable operation type
  CachedObservable,
) where

import Control.Applicative
import Data.Functor.Identity
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry

-- * Cache

newtype CachedObservable canLoad exceptions c v = CachedObservable (TVar (CacheState canLoad exceptions c v))

data CacheState canLoad exceptions c v
  = forall a. IsObservableCore canLoad exceptions c v a => CacheIdle a
  | forall a. IsObservableCore canLoad exceptions c v a
    => CacheAttached
      a
      TDisposer
      (CallbackRegistry (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v))
      (ObserverState canLoad (ObservableResult exceptions c) v)

instance (ObservableContainer c v, ContainerConstraint canLoad exceptions c v (CachedObservable canLoad exceptions c v)) => ToObservableT canLoad exceptions c v (CachedObservable canLoad exceptions c v) where
  toObservableT = ObservableT

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (CachedObservable canLoad exceptions c v) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry state -> pure (toObservableState state)

  attachEvaluatedObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, state) <- attachEvaluatedObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry (createObserverState state))
        disposer <- registerCallback registry callback
        pure (disposer, state)
      CacheAttached _ _ registry state -> do
        case state of
          -- The cached state can't be propagated downstream, so the first
          -- callback invocation must not send a Delta or a LiveUnchanged.
          -- The callback is wrapped to change them to a Replace.
          ObserverStateLoadingCached cache -> do
            disposer <- registerCallbackChangeAfterFirstCall registry (callback . fixInvalidCacheState cache) callback
            pure (disposer, ObservableStateLoading)
          _ -> do
            disposer <- registerCallback registry callback
            pure (disposer, toObservableState state)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTDisposer upstreamDisposer
      updateCache :: EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()
      updateCache change = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry oldState -> do
            let mstate = applyEvaluatedObservableChange change oldState
            forM_ mstate \state -> do
              writeTVar var (CacheAttached upstream upstreamDisposer registry state)
              callCallbacks registry change

  isCachedObservable# _ = True

-- Precondition: Observer is in `ObserverStateLoadingCleared` state, but caller
-- assumes the observer is in `ObserverStateLoadingCached` state.
fixInvalidCacheState ::
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
  -- Filtered by `applyEvaluatedObservableChange` in `updateCache`
  impossibleCodePath

cacheObservable ::
  MonadSTMc NoRetry '[] m =>
  Observable canLoad exceptions v -> m (Observable canLoad exceptions v)
cacheObservable (Observable f) = Observable <$> cacheObservableT f

cacheObservableT ::
  (
    ObservableContainer c v,
    ContainerConstraint canLoad exceptions c v (CachedObservable canLoad exceptions c v),
    MonadSTMc NoRetry '[] m
  ) =>
  ObservableT canLoad exceptions c v -> m (ObservableT canLoad exceptions c v)
cacheObservableT f =
  if isCachedObservable# f
    then pure f
    else ObservableT . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

newtype CacheObservableOperation canLoad exceptions l e v = CacheObservableOperation (Observable l e v)

instance ToObservableT canLoad exceptions Identity (Observable l e v) (CacheObservableOperation canLoad exceptions l e v) where
  toObservableT = ObservableT

instance IsObservableCore canLoad exceptions Identity (Observable l e v) (CacheObservableOperation canLoad exceptions l e v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (pure cache)
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, ObservableStateLive (pure cache))

-- | Cache an observable in the `Observable` monad. Use with care! A new cache
-- is created for every outer observable evaluation.
observeCachedObservable :: forall canLoad exceptions e l v a. ToObservable l e v a => a -> Observable canLoad exceptions (Observable l e v)
observeCachedObservable x =
  toObservable (CacheObservableOperation @canLoad @exceptions (toObservable x))
