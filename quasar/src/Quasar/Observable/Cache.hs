{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Cache (
  cacheObservable,
  cacheObservableOperation,
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix

-- * Cache

newtype CachedObservable canWait exceptions delta value = CachedObservable (TVar (CacheState canWait exceptions delta value))

data CacheState canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => CacheIdle a
  | forall a. IsGeneralizedObservable canWait exceptions delta value a =>
    CacheAttached
      a
      TSimpleDisposer
      (CallbackRegistry (Final, ObservableChangeWithState canWait exceptions delta value))
      (ObservableState canWait exceptions value)
  | CacheFinalized (ObservableState canWait exceptions value)

instance ObservableContainer delta value => ToGeneralizedObservable canWait exceptions delta value (CachedObservable canWait exceptions delta value)

instance ObservableContainer delta value => IsGeneralizedObservable canWait exceptions delta value (CachedObservable canWait exceptions delta value) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry state -> pure (False, state)
      CacheFinalized state -> pure (True, state)
  attachStateObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, final, value) <- attachStateObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry value)
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, final, value)
      CacheAttached _ _ registry value -> do
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, False, value)
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
      updateCache :: Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()
      updateCache final change = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry _ ->
            if final
              then do
                writeTVar var (CacheFinalized (changeWithStateToState change))
                callCallbacks registry (final, change)
                clearCallbackRegistry registry
              else do
                writeTVar var (CacheAttached upstream upstreamDisposer registry (changeWithStateToState change))
                callCallbacks registry (final, change)
          CacheFinalized _ -> pure () -- Upstream implementation error

  isCachedObservable# _ = True

cacheObservable :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> m (GeneralizedObservable canWait exceptions delta value)
cacheObservable x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    y@(GeneralizedObservable f) ->
      if isCachedObservable# f
        then pure y
        else GeneralizedObservable . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canWait exceptions w e d v = forall a. ToGeneralizedObservable w e d v a => CacheObservableOperation a

instance ToGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v)

instance IsGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (True, ObservableStateValue (Right cache))
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, True, ObservableStateValue (Right cache))

-- | Cache an observable in the `Observable` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
cacheObservableOperation :: forall canWait exceptions w e d v a. ToGeneralizedObservable w e d v a => a -> Observable canWait exceptions (GeneralizedObservable w e d v)
cacheObservableOperation x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    (GeneralizedObservable f) -> Observable (GeneralizedObservable (CacheObservableOperation @canWait @exceptions f))
