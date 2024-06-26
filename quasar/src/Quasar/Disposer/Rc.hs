module Quasar.Disposer.Rc (
  Rc,
  newRc,
  newRcIO,
  tryReadRc,
  tryReadRcIO,
  readRc,
  readRcIO,
  tryDuplicateRc,
  duplicateRc,
  tryExtractRc,
  consumeRc,
) where

import Quasar.Prelude
import Quasar.Disposer
import Quasar.Disposer.DisposableVar
import Quasar.Exceptions (mkDisposedException, DisposedException(..))
import Control.Exception (finally)

-- | A Rc is a disposable readonly data structure that can be cloned. Every copy
-- has an independent lifetime. The content is disposed when all copies of the
-- Rc are disposed.
newtype Rc a = Rc (DisposableVar (RcHandle a))
  deriving (Eq, Hashable, Disposable)

data RcHandle a = Disposable a => RcHandle {
  -- Refcount that tracks how many locks exists in this group of locks.
  lockCount :: TVar Word64,
  content :: a
}

decrementRc :: RcHandle a -> STMc NoRetry '[] Disposer
decrementRc rc@RcHandle{} = do
  let lockCount = rc.lockCount
  c <- readTVar lockCount
  case c of
    -- Special case - when called from `tryExtractRc` we should not run the
    -- cleanup function
    0 -> pure mempty

    -- Last owner disposed, run cleanup
    1 -> do
      writeTVar rc.lockCount 0
      pure (getDisposer rc.content)

    -- Decrement rc count
    _ -> mempty <$ writeTVar rc.lockCount (pred c)

-- | Extract the content of an Rc without disposing the content. This only has
-- an effect if there are no other vars in the same group.
tryExtractRc :: Rc a -> STMc NoRetry '[] (Maybe a)
tryExtractRc (Rc var) = do
  tryReadDisposableVar var >>= \case
    Nothing -> pure Nothing
    Just rc -> do
      c <- readTVar rc.lockCount
      if c == 1
        then do
          -- Set count to 0, which prevents the cleanup function from running
          writeTVar rc.lockCount 0
          -- Dispose DisposableVar to make content unavailable through the Rc
          disposeEventually# var
          pure (Just rc.content)

        else pure Nothing

newRc :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m (Rc a)
newRc content = liftSTMc @NoRetry @'[] do
  lockCount <- newTVar 1
  let rc = RcHandle {
    lockCount,
    content
  }
  Rc <$> newSpecialDisposableVar decrementRc rc

newRcIO :: (Disposable a, MonadIO m) => a -> m (Rc a)
newRcIO content = liftIO do
  lockCount <- newTVarIO 1
  let rc = RcHandle {
    lockCount,
    content
  }
  Rc <$> newSpecialDisposableVarIO decrementRc rc

-- | Read the content of the lock, if the lock has not been disposed.
tryReadRc :: MonadSTMc NoRetry '[] m => Rc a -> m (Maybe a)
tryReadRc (Rc var) = liftSTMc @NoRetry @'[] do
  (.content) <<$>> tryReadDisposableVar var

-- | Read the content of the lock, if the lock has not been disposed.
tryReadRcIO :: MonadIO m => Rc a -> m (Maybe a)
tryReadRcIO (Rc var) = liftIO do
  (.content) <<$>> tryReadDisposableVarIO var

readRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m a
readRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryReadRc rc

readRcIO :: (MonadIO m, HasCallStack) => Rc a -> m a
readRcIO rc = liftIO do
  maybe (throwIO mkDisposedException) pure =<< tryReadRcIO rc

-- | Produces a _new_ lock that points to the same content, but has an
-- independent lifetime. The caller has to ensure the new lock is disposed.
--
-- Usually this would be used to pass a copy of the lock to another component.
tryDuplicateRc :: MonadSTMc NoRetry '[] m => Rc a -> m (Maybe (Rc a))
tryDuplicateRc (Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    Rc <$> newSpecialDisposableVar decrementRc rc

duplicateRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m (Rc a)
duplicateRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryDuplicateRc rc

consumeRc :: HasCallStack => Rc a -> (a -> IO b) -> IO b
consumeRc rc fn = do
  flip finally (dispose rc) do
    tryReadRcIO rc >>= \case
      Nothing -> liftIO $ throwC mkDisposedException
      Just content -> fn content
