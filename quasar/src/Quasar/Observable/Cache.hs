{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Cache (
  cacheObservable,
  cacheObservableOperation,
) where

import Control.Applicative
import Control.Monad.Except
import Data.Functor.Identity
import Quasar.Observable.Core
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix

-- * Cache

newtype CachedObservable canWait exceptions value = CachedObservable (TVar (CacheState canWait exceptions value))

data CacheState canWait exceptions value
  = forall a. IsGeneralizedObservable canWait exceptions value a => CacheIdle a
  | forall a. IsGeneralizedObservable canWait exceptions value a =>
    CacheAttached
      a
      TSimpleDisposer
      (CallbackRegistry (Final, ObservableChangeWithState canWait exceptions value))
      (ObservableState canWait exceptions value)
  | CacheFinalized (ObservableState canWait exceptions value)

instance ObservableContainer value => ToGeneralizedObservable canWait exceptions value (CachedObservable canWait exceptions value)

instance ObservableContainer value => IsGeneralizedObservable canWait exceptions value (CachedObservable canWait exceptions value) where
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
      updateCache :: Final -> ObservableChangeWithState canWait exceptions value -> STMc NoRetry '[] ()
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

cacheObservable :: (ToGeneralizedObservable canWait exceptions value a, MonadSTMc NoRetry '[] m) => a -> m (GeneralizedObservable canWait exceptions value)
cacheObservable x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    y@(GeneralizedObservable f) ->
      if isCachedObservable# f
        then pure y
        else GeneralizedObservable . CachedObservable <$> newTVar (CacheIdle f)


-- ** Embedded cache in the Observable monad

data CacheObservableOperation canWait exceptions w e v = forall a. ToGeneralizedObservable w e v a => CacheObservableOperation a

instance ToGeneralizedObservable canWait exceptions (Identity (GeneralizedObservable w e v)) (CacheObservableOperation canWait exceptions w e v)

instance IsGeneralizedObservable canWait exceptions (Identity (GeneralizedObservable w e v)) (CacheObservableOperation canWait exceptions w e v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (True, ObservableStateValue (Right (Identity cache)))
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, True, ObservableStateValue (Right (Identity cache)))

-- | Cache an observable in the `Observable` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
cacheObservableOperation :: forall canWait exceptions w e v a. ToGeneralizedObservable w e v a => a -> Observable canWait exceptions (GeneralizedObservable w e v)
cacheObservableOperation x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    (GeneralizedObservable f) -> Observable (GeneralizedObservable (CacheObservableOperation @canWait @exceptions f))
