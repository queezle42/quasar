module Quasar.Async (
  -- * Async
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,

  -- ** Async with explicit error handling
  handleAsync,
  handleAsync_,
  handleAsyncWithUnmask,
  handleAsyncWithUnmask_,

  -- ** Async exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
) where

import Control.Monad.Catch
import Control.Monad.Reader
import Quasar.Async.Unmanaged
import Quasar.Awaitable
import Quasar.Prelude
import Quasar.ResourceManager

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions unmasked.
async :: MonadResourceManager m => (ResourceManagerIO a) -> m (Awaitable a)
async action = asyncWithUnmask \unmask -> unmask action

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions masked and will be passed an action that can be used to unmask.
asyncWithUnmask :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m (Awaitable r)
asyncWithUnmask action = do
  resourceManager <- askResourceManager
  handleAsyncWithUnmask (throwToResourceManager resourceManager) action

async_ :: MonadResourceManager m => (ResourceManagerIO ()) -> m ()
async_ action = void $ async action

asyncWithUnmask_ :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions unmasked. When an exception is thrown that is not caused from
-- the disposable instance (i.e. the task being canceled), the handler is called with that exception.
handleAsyncWithUnmask :: MonadResourceManager m => (SomeException -> IO ()) -> ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m (Awaitable r)
handleAsyncWithUnmask handler action = do
  resourceManager <- askResourceManager
  toAwaitable <$> registerNewResource do
    coreAsyncImplementation wrappedHandler \unmask ->
      onResourceManager resourceManager (action (liftUnmask unmask))
  where
    wrappedHandler :: SomeException -> IO ()
    wrappedHandler (fromException -> Just AsyncDisposed) = pure ()
    wrappedHandler ex = handler ex
    liftUnmask :: (forall b. IO b -> IO b) -> ResourceManagerIO a -> ResourceManagerIO a
    liftUnmask unmask innerAction = do
      resourceManager <- askResourceManager
      liftIO $ unmask $ onResourceManager resourceManager innerAction

handleAsyncWithUnmask_ :: MonadResourceManager m => (SomeException -> IO ()) -> ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m ()
handleAsyncWithUnmask_ handler action = void $ handleAsyncWithUnmask handler action

handleAsync :: MonadResourceManager m => (SomeException -> IO ()) -> ResourceManagerIO r -> m (Awaitable r)
handleAsync handler action = handleAsyncWithUnmask handler \unmask -> unmask action

handleAsync_ :: MonadResourceManager m => (SomeException -> IO ()) -> ResourceManagerIO r -> m ()
handleAsync_ handler action = void $ handleAsync handler action
