module Quasar.Disposer.Rc (
  Rc,
  newRc,
  newRcIO,
  readRc,
  tryReadRc,
  readRcIO,
  tryReadRcIO,
  cloneRc,
  tryCloneRc,
  unwrapRc,
  tryUnwrapRc,
  extractRc,
  tryExtractRc,
  cloneAndExtractRc,
  tryCloneAndExtractRc,
  consumeRc,
  bracketRc,
  mapRc,
  tryMapRc,
) where

import Quasar.Disposer
import Quasar.Disposer.DisposableVar
import Quasar.Exceptions (mkDisposedException, DisposedException(..))
import Quasar.Prelude
import Control.Monad.Catch (MonadMask)

-- | A Rc is a disposable readonly data structure that can be cloned. Every copy
-- has an independent lifetime. The content is disposed when all copies of the
-- Rc are disposed.
newtype Rc a = Rc (DisposableVar (RcHandle a))
  deriving (Eq, Hashable, Disposable)

data RcHandle a = RcHandle {
  -- Refcount that tracks how many locks exists in this group of locks.
  lockCount :: TVar Word64,
  disposer :: Disposer,
  content :: a
}

decrementRc :: RcHandle a -> STMc NoRetry '[] Disposer
decrementRc rcHandle = do
  let lockCount = rcHandle.lockCount
  c <- readTVar lockCount
  case c of
    -- Special case - when called from `tryExtractRc` we should not run the
    -- cleanup function
    0 -> pure mempty

    -- Last owner disposed, run cleanup
    1 -> do
      writeTVar rcHandle.lockCount 0
      pure rcHandle.disposer

    -- Decrement rc count
    _ -> mempty <$ writeTVar rcHandle.lockCount (pred c)

newRc :: MonadSTMc NoRetry '[] m => Owned a -> m (Rc a)
newRc (Owned disposer content) = liftSTMc @NoRetry @'[] do
  lockCount <- newTVar 1
  let rc = RcHandle {
    lockCount,
    disposer,
    content
  }
  Rc <$> newSpecialDisposableVar decrementRc rc

newRcIO :: MonadIO m => Owned a -> m (Rc a)
newRcIO (Owned disposer content) = liftIO do
  lockCount <- newTVarIO 1
  let rc = RcHandle {
    lockCount,
    disposer,
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
tryCloneRc :: MonadSTMc NoRetry '[] m => Rc a -> m (Maybe (Rc a))
tryCloneRc (Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    Rc <$> newSpecialDisposableVar decrementRc rc

cloneRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m (Rc a)
cloneRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryCloneRc rc

-- | Combination of `tryCloneRc` and `tryExtractRc` with an optimized
-- implementation.
tryCloneAndExtractRc :: MonadSTMc NoRetry '[] m => Rc a -> m (Maybe (Owned a))
tryCloneAndExtractRc (Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rcHandle -> do
    modifyTVar rcHandle.lockCount succ
    newVar <- newSpecialDisposableVar decrementRc rcHandle
    pure (Owned (getDisposer newVar) rcHandle.content)

-- | Combination of `cloneRc` and `extractRc` with an optimized implementation.
--
-- Produces a _new_ lock that points to the same content, but has an
-- independent lifetime. The caller has to ensure the new lock is disposed.
--
-- Usually this would be used to pass a copy of the lock to another component.
cloneAndExtractRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m (Owned a)
cloneAndExtractRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryCloneAndExtractRc rc


-- | Returns the inner value if the `Rc` has exactly one strong reference.
tryUnwrapRc ::
  MonadSTMc NoRetry '[] m =>
  Rc a -> m (Maybe (Owned a))
tryUnwrapRc (Rc var) = liftSTMc do
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
          pure (Just (Owned rc.disposer rc.content))

        else pure Nothing

-- | Returns the inner value if the `Rc` has exactly one strong reference.
unwrapRc ::
  MonadSTMc NoRetry '[DisposedException] m =>
  Rc a -> m (Owned a)
unwrapRc rc = maybe (throwC mkDisposedException) pure =<< tryUnwrapRc rc

tryExtractRc ::
  MonadSTMc NoRetry '[] m =>
  Rc a -> m (Maybe (Owned a))
tryExtractRc rc@(Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rcHandle -> do
    modifyTVar rcHandle.lockCount succ
    disposer <- getDisposer <$> newSpecialDisposableVar decrementRc rcHandle
    disposeEventually_ rc
    pure (Owned disposer rcHandle.content)

extractRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m (Owned a)
extractRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryExtractRc rc


consumeRc :: (MonadIO m, MonadMask m, HasCallStack) => Rc a -> (a -> m b) -> m b
consumeRc rc fn = bracketOwned (atomically (extractRc rc)) fn

bracketRc :: (MonadIO m, MonadMask m, HasCallStack) => m (Rc a) -> (a -> m b) -> m b
bracketRc aquire fn = bracketOwned (atomically . extractRc =<< aquire) fn



tryMapRc :: MonadSTMc NoRetry '[] m => (a -> b) -> Rc a -> m (Maybe (Rc b))
tryMapRc fn rc@(Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rcHandle -> do
    modifyTVar rcHandle.lockCount succ
    disposeEventually_ rc
    Rc <$> newSpecialDisposableVar decrementRc rcHandle {
      content = fn rcHandle.content
    }

mapRc :: MonadSTMc NoRetry '[DisposedException] m => (a -> b) -> Rc a -> m (Rc b)
mapRc fn rc = maybe (throwC mkDisposedException) pure =<< tryMapRc fn rc
