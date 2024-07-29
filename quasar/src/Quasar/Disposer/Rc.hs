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

import Control.Monad.Catch (MonadMask)
import Quasar.Disposer
import Quasar.Disposer.DisposableVar
import Quasar.Exceptions (mkDisposedException, DisposedException(..))
import Quasar.Future
import Quasar.Prelude

-- | A Rc is a disposable readonly data structure that can be cloned. Every copy
-- has an independent lifetime. The content is disposed when all copies of the
-- Rc are disposed.
newtype Rc a = Rc (DisposableVar (RcHandle a))
  deriving (Eq, Hashable)

instance ToFuture '[] () (Rc a) where
  toFuture (Rc var) = toFuture var

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

newRc :: MonadSTMc NoRetry '[] m => Owned a -> m (Owned (Rc a))
newRc (Owned disposer content) = liftSTMc @NoRetry @'[] do
  lockCount <- newTVar 1
  let rc = RcHandle {
    lockCount,
    disposer,
    content
  }
  var <- newSpecialDisposableVar decrementRc rc
  pure (Owned (getDisposer var) (Rc var))

newRcIO :: MonadIO m => Owned a -> m (Owned (Rc a))
newRcIO (Owned disposer content) = liftIO do
  lockCount <- newTVarIO 1
  let rc = RcHandle {
    lockCount,
    disposer,
    content
  }
  var <- newSpecialDisposableVarIO decrementRc rc
  pure (Owned (getDisposer var) (Rc var))

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
tryCloneRc :: MonadSTMc NoRetry '[] m => Rc a -> m (Maybe (Owned (Rc a)))
tryCloneRc (Rc var) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rc -> do
    modifyTVar rc.lockCount succ
    newVar <- newSpecialDisposableVar decrementRc rc
    pure (Owned (getDisposer newVar) (Rc newVar))

cloneRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Rc a -> m (Owned (Rc a))
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
  HasCallStack =>
  MonadIO m =>
  Owned (Rc a) -> m (Owned (Either (Rc a) a))
tryUnwrapRc (Owned originalDisposer originalRc) = liftIO do
  atomically (tryCloneRc originalRc) >>= \case
    Nothing -> do
      dispose originalDisposer
      throwC mkDisposedException
    Just rc@(Owned _ (Rc var)) -> do
      dispose originalDisposer
      atomically do
        rcHandle <- readDisposableVar var
        c <- readTVar rcHandle.lockCount
        if c == 1
          then do
            -- Set count to 0, which prevents the cleanup function from running
            writeTVar rcHandle.lockCount 0
            -- Dispose DisposableVar to make content unavailable through the Rc
            disposeEventually var
            pure (Owned rcHandle.disposer (Right rcHandle.content))

        else pure (Left <$> rc)

-- | Returns the inner value if the `Rc` has exactly one strong reference.
unwrapRc ::
  MonadIO m =>
  Owned (Rc a) -> m (Owned a)
unwrapRc rc = tryUnwrapRc rc >>= \case
  Owned disposer (Right result) -> pure (Owned disposer result)
  Owned disposer (Left clonedRc) -> do
    dispose disposer
    liftIO $ fail "foo"

tryExtractRc ::
  MonadSTMc NoRetry '[] m =>
  Owned (Rc a) -> m (Maybe (Owned a))
tryExtractRc (Owned originalDisposer (Rc var)) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar var >>= mapM \rcHandle -> do
    modifyTVar rcHandle.lockCount succ
    disposer <- getDisposer <$> newSpecialDisposableVar decrementRc rcHandle
    disposeEventually_ originalDisposer
    pure (Owned disposer rcHandle.content)

extractRc ::
  (MonadSTMc NoRetry '[DisposedException] m, HasCallStack) =>
  Owned (Rc a) -> m (Owned a)
extractRc rc = liftSTMc @NoRetry @'[DisposedException] do
  maybe (throwC mkDisposedException) pure =<< tryExtractRc rc


consumeRc :: (MonadIO m, MonadMask m, HasCallStack) => Owned (Rc a) -> (a -> m b) -> m b
consumeRc rc fn = bracketOwned (atomically (extractRc rc)) fn

bracketRc :: (MonadIO m, MonadMask m, HasCallStack) => m (Owned (Rc a)) -> (a -> m b) -> m b
bracketRc aquire fn = bracketOwned (atomically . extractRc =<< aquire) fn


tryMapRc :: MonadSTMc NoRetry '[] m => (a -> b) -> Owned (Rc a) -> m (Maybe (Owned (Rc b)))
tryMapRc fn (Owned disposer (Rc originalVar)) = liftSTMc @NoRetry @'[] do
  tryReadDisposableVar originalVar >>= mapM \rcHandle -> do
    modifyTVar rcHandle.lockCount succ
    disposeEventually_ disposer
    var <- newSpecialDisposableVar decrementRc rcHandle {
      content = fn rcHandle.content
    }
    pure (Owned (getDisposer var) (Rc var))

mapRc :: MonadSTMc NoRetry '[DisposedException] m => (a -> b) -> Owned (Rc a) -> m (Owned (Rc b))
mapRc fn rc = maybe (throwC mkDisposedException) pure =<< tryMapRc fn rc
