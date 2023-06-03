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
  = forall a. IsObservableCore canLoad c v a => CacheIdle a
  | forall a. IsObservableCore canLoad c v a =>
    CacheAttached
      a
      TSimpleDisposer
      (CallbackRegistry (Final, EvaluatedObservableChange canLoad c v))
      (ObserverState canLoad c v)
  | CacheFinalized (ObservableState canLoad c v)

instance ObservableContainer c v => IsObservableCore canLoad c v (CachedObservable canLoad c v) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry (ObserverStateLive state) -> pure (False, state)
      CacheFinalized (ObservableStateLive state) -> pure (True, state)
  attachEvaluatedObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, final, state) <- attachEvaluatedObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry (createObserverState state))
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, final, state)
      CacheAttached _ _ registry value -> do
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, False, toObservableState value)
      CacheFinalized value -> pure (mempty, True, value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTSimpleDisposer upstreamDisposer
          CacheFinalized _ -> pure ()
      updateCache :: Final -> EvaluatedObservableChange canLoad c v -> STMc NoRetry '[] ()
      updateCache final change = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry oldState -> do
            let mstate = applyEvaluatedObservableChange change oldState
            if final
              then do
                writeTVar var (CacheFinalized (toObservableState (fromMaybe oldState mstate)))
                callCallbacks registry (final, change)
                clearCallbackRegistry registry
              else do
                forM_ mstate \state -> do
                  writeTVar var (CacheAttached upstream upstreamDisposer registry state)
                  callCallbacks registry (final, change)
          CacheFinalized _ -> pure () -- Upstream implementation error

  isCachedObservable# _ = True

cacheObservable :: (ToObservable canLoad exceptions c v a, MonadSTMc NoRetry '[] m) => a -> m (Observable canLoad exceptions c v)
cacheObservable x =
  case toObservable x of
    c@(ConstObservable _) -> pure c
    (DynObservable f) -> Observable <$> cacheObservable# f

cacheObservable# :: (IsObservableCore canLoad c v a, MonadSTMc NoRetry '[] m) => a -> m (ObservableCore canLoad c v)
cacheObservable# f =
  if isCachedObservable# f
    then pure (DynObservableCore f)
    else DynObservableCore . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canLoad exceptions l e c v = forall a. ToObservable l e c v a => CacheObservableOperation a

instance IsObservableCore canLoad (ObservableResult exceptions Identity) (Observable l e c v) (CacheObservableOperation canLoad exceptions l e c v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (True, pure cache)
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, True, ObservableStateLive (pure cache))

-- | Cache an observable in the `ObservableI` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
observeCachedObservable :: forall canLoad exceptions e l c v a. ToObservable l e c v a => a -> Observable canLoad exceptions Identity (Observable l e c v)
observeCachedObservable x =
  case toObservable x of
    c@(ConstObservable _) -> pure c
    f@(DynObservable _) -> DynObservable (CacheObservableOperation @canLoad @exceptions f)
