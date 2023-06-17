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

newtype CachedObservable canLoad c v = CachedObservable (TVar (CacheState canLoad c v))

data CacheState canLoad c v
  = CacheIdle (ObservableCore canLoad c v)
  | CacheAttached
      (ObservableCore canLoad c v)
      TSimpleDisposer
      (CallbackRegistry (EvaluatedObservableChange canLoad c v))
      (ObserverState canLoad c v)

instance ObservableContainer c v => IsObservableCore canLoad c v (CachedObservable canLoad c v) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry (ObserverStateLive state) -> pure state
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
      updateCache :: EvaluatedObservableChange canLoad c v -> STMc NoRetry '[] ()
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
cacheObservable (toObservable -> Observable x) = Observable <$> cacheObservableCore x

cacheObservableCore :: (MonadSTMc NoRetry '[] m, ObservableContainer c v) => ObservableCore canLoad c v -> m (ObservableCore canLoad c v)
cacheObservableCore f =
  if isCachedObservable# f
    then pure (ObservableCore f)
    else ObservableCore . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canLoad exceptions l e c v = forall a. ToObservable l e c v a => CacheObservableOperation a

instance IsObservableCore canLoad (ObservableResult exceptions Identity) (Observable l e c v) (CacheObservableOperation canLoad exceptions l e c v) where
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
  Observable (ObservableCore (CacheObservableOperation @canLoad @exceptions (toObservable x)))
