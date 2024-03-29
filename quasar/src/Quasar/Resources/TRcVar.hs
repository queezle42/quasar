module Quasar.Resources.TRcVar (
  TRcVar,
  newTRcVar,
  newTRcVarIO,
  tryReadTRcVar,
  tryDuplicateTRcVar,
) where

import Quasar.Prelude
import Quasar.Resources
import Quasar.Resources.DisposableVar

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

