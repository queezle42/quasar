module Quasar.Resources.Lock (
  Lock,
  newLock,
  newLockIO,
  tryReadLock,
  tryDuplicateLock,
) where

import Quasar.Prelude
import Quasar.Resources
import Quasar.Resources.DisposableVar

-- | A Lock is a disposable storage (like a `TDisposableVar`) that can be
-- cloned. Every copy has an independent lifetime.
newtype Lock a = Lock (TDisposableVar (LockRc a))
  deriving (Disposable, TDisposable)

data LockRc a = LockRc {
  -- Refcount that tracks how many locks exists in this group of locks.
  lockCount :: TVar Word64,
  -- A release function. Called when the last lock of the group is disposed.
  cleanup :: a -> STMc NoRetry '[] (),
  content :: a
}

decrementLock :: LockRc a -> STMc NoRetry '[] ()
decrementLock rc = do
  let lockCount = rc.lockCount
  c <- readTVar lockCount
  writeTVar rc.lockCount (pred c)
  when (c == 0) (rc.cleanup rc.content)

newLock :: MonadSTMc NoRetry '[] m => (a -> STMc NoRetry '[] ()) -> a -> m (Lock a)
newLock cleanup content = do
  lockCount <- newTVar 1
  let rc = LockRc {
    lockCount,
    cleanup,
    content
  }
  Lock <$> newTDisposableVar rc decrementLock

newLockIO :: MonadIO m => (a -> STMc NoRetry '[] ()) -> a -> m (Lock a)
newLockIO cleanup content = do
  lockCount <- newTVarIO 1
  let rc = LockRc {
    lockCount,
    cleanup,
    content
  }
  Lock <$> newTDisposableVarIO rc decrementLock

-- | Read the content of the lock, if the lock has not been disposed.
tryReadLock :: MonadSTMc NoRetry '[] m => Lock a -> m (Maybe a)
tryReadLock (Lock var) = liftSTMc @NoRetry @'[] do
  (.content) <<$>> tryReadTDisposableVar var

-- | Produces a _new_ lock that points to the same content, but has an
-- independent lifetime. The caller has to ensure the new lock is disposed.
--
-- Usually this would be used to pass a copy of the lock to another component.
tryDuplicateLock :: MonadSTMc NoRetry '[] m => Lock a -> m (Maybe (Lock a))
tryDuplicateLock (Lock var) = liftSTMc @NoRetry @'[] do
  tryReadTDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    Lock <$> newTDisposableVar rc decrementLock

