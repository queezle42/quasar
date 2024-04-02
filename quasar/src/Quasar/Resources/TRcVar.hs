module Quasar.Resources.TRcVar (
  RcVar,
  newRcVar,
  newRcVarIO,
  tryReadRcVar,
  tryDuplicateRcVar,

  TRcVar,
  newTRcVar,
  newTRcVarIO,
  newFnRcVar,
  newFnRcVarIO,
  tryReadTRcVar,
  tryDuplicateTRcVar,
) where

import Quasar.Prelude
import Quasar.Resources
import Quasar.Resources.DisposableVar
import Quasar.Exceptions (ExceptionSink)

-- | A TRcVar is a disposable storage (like a `TDisposableVar`) that can be
-- cloned. Every copy has an independent lifetime.
newtype TRcVar a = TRcVar (TDisposableVar (TRcVarRc a))
  deriving (Disposable, TDisposable)

data TRcVarRc a = TRcVarRc {
  -- Refcount that tracks how many locks exists in this group of locks.
  lockCount :: TVar Word64,
  -- A release function. Called when the last lock of the group is disposed.
  cleanup :: a -> STMc NoRetry '[] (),
  content :: a
}

decrementTRcVar :: TRcVarRc a -> STMc NoRetry '[] ()
decrementTRcVar rc = do
  let lockCount = rc.lockCount
  c <- readTVar lockCount
  writeTVar rc.lockCount (pred c)
  when (c == 0) (rc.cleanup rc.content)

newTRcVar :: MonadSTMc NoRetry '[] m => (a -> STMc NoRetry '[] ()) -> a -> m (TRcVar a)
newTRcVar cleanup content = do
  lockCount <- newTVar 1
  let rc = TRcVarRc {
    lockCount,
    cleanup,
    content
  }
  TRcVar <$> newTDisposableVar rc decrementTRcVar

newTRcVarIO :: MonadIO m => (a -> STMc NoRetry '[] ()) -> a -> m (TRcVar a)
newTRcVarIO cleanup content = do
  lockCount <- newTVarIO 1
  let rc = TRcVarRc {
    lockCount,
    cleanup,
    content
  }
  TRcVar <$> newTDisposableVarIO rc decrementTRcVar

-- | Read the content of the lock, if the lock has not been disposed.
tryReadTRcVar :: MonadSTMc NoRetry '[] m => TRcVar a -> m (Maybe a)
tryReadTRcVar (TRcVar var) = liftSTMc @NoRetry @'[] do
  (.content) <<$>> tryReadTDisposableVar var

-- | Produces a _new_ lock that points to the same content, but has an
-- independent lifetime. The caller has to ensure the new lock is disposed.
--
-- Usually this would be used to pass a copy of the lock to another component.
tryDuplicateTRcVar :: MonadSTMc NoRetry '[] m => TRcVar a -> m (Maybe (TRcVar a))
tryDuplicateTRcVar (TRcVar var) = liftSTMc @NoRetry @'[] do
  tryReadTDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    TRcVar <$> newTDisposableVar rc decrementTRcVar



-- | A RcVar is a disposable storage (like a `DisposableVar`) that can be
-- cloned. Every copy has an independent lifetime.
newtype RcVar a = RcVar (DisposableVar (RcVarRc a))
  deriving Disposable

data RcVarRc a = RcVarRc {
  -- Refcount that tracks how many locks exists in this group of locks.
  lockCount :: TVar Word64,
  -- A release function. Called when the last lock of the group is disposed.
  cleanup :: a -> STMc NoRetry '[] Disposer,
  content :: a
}

decrementRcVar :: RcVarRc a -> STMc NoRetry '[] Disposer
decrementRcVar rc = do
  let lockCount = rc.lockCount
  c <- readTVar lockCount
  writeTVar rc.lockCount (pred c)
  if c == 0
    then rc.cleanup rc.content
    else pure mempty

newRcVar :: MonadSTMc NoRetry '[] m => (a -> STMc NoRetry '[] Disposer) -> a -> m (RcVar a)
newRcVar cleanup content = liftSTMc @NoRetry @'[] do
  lockCount <- newTVar 1
  let rc = RcVarRc {
    lockCount,
    cleanup,
    content
  }
  RcVar <$> newDisposableVar decrementRcVar rc

newFnRcVar :: MonadSTMc NoRetry '[] m => ExceptionSink -> (a -> IO ()) -> a -> m (RcVar a)
newFnRcVar sink cleanup = liftSTMc @NoRetry @'[] .
  newRcVar \value -> newUnmanagedIODisposer (cleanup value) sink

newRcVarIO :: MonadIO m => (a -> STMc NoRetry '[] Disposer) -> a -> m (RcVar a)
newRcVarIO cleanup content = liftIO do
  lockCount <- newTVarIO 1
  let rc = RcVarRc {
    lockCount,
    cleanup,
    content
  }
  RcVar <$> newDisposableVarIO decrementRcVar rc

newFnRcVarIO :: MonadIO m => ExceptionSink -> (a -> IO ()) -> a -> m (RcVar a)
newFnRcVarIO sink cleanup = liftIO .
  newRcVarIO \value -> newUnmanagedIODisposer (cleanup value) sink

-- | Read the content of the lock, if the lock has not been disposed.
tryReadRcVar :: MonadSTMc NoRetry '[] m => RcVar a -> m (Maybe a)
tryReadRcVar (RcVar var) = liftSTMc @NoRetry @'[] do
  (.content) <<$>> tryReadDisposableVar var

-- | Produces a _new_ lock that points to the same content, but has an
-- independent lifetime. The caller has to ensure the new lock is disposed.
--
-- Usually this would be used to pass a copy of the lock to another component.
tryDuplicateRcVar :: MonadSTMc NoRetry '[] m => RcVar a -> m (Maybe (RcVar a))
tryDuplicateRcVar (RcVar var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    RcVar <$> newDisposableVar decrementRcVar rc

