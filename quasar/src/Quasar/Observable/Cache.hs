{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Cache (
  cacheObservable,
  observeCachedObservable,
) where

import Control.Applicative
import Control.Monad.Except
import Data.Functor.Identity
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry

-- * Cache

newtype CachedObservable canLoad exceptions c v = CachedObservable (TVar (CacheState canLoad exceptions c v))

data CacheState canLoad exceptions c v
  = CacheIdle (Observable canLoad exceptions c v)
  | CacheAttached
      (Observable canLoad exceptions c v)
      TSimpleDisposer
      (CallbackRegistry (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v))
      (ObserverState canLoad (ObservableResult exceptions c) v)

instance ObservableContainer c v => IsObservableCore canLoad exceptions c v (CachedObservable canLoad exceptions c v) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry (ObserverStateLive state) -> unwrapObservableResult state
  attachEvaluatedObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, state) <- attachEvaluatedObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry (createObserverState state))
        disposer <- registerCallback registry callback
        pure (disposer, state)
      CacheAttached _ _ registry value -> do
        disposer <- registerCallback registry callback
        pure (disposer, toObservableState value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTSimpleDisposer upstreamDisposer
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

cacheObservable :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> m (Observable canLoad exceptions c v)
cacheObservable (toObservable -> f) =
  if isCachedObservable# f
    then pure f
    else Observable . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canLoad exceptions l e c v = forall a. ToObservable l e c v a => CacheObservableOperation a

instance IsObservableCore canLoad exceptions Identity (Observable l e c v) (CacheObservableOperation canLoad exceptions l e c v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (pure cache)
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, ObservableStateLive (pure cache))

-- | Cache an observable in the `ObservableI` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
observeCachedObservable :: forall canLoad exceptions e l c v a. ToObservable l e c v a => a -> Observable canLoad exceptions Identity (Observable l e c v)
observeCachedObservable x =
  Observable (CacheObservableOperation @canLoad @exceptions (toObservable x))
