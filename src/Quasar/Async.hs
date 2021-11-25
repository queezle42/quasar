module Quasar.Async (
  -- * Async
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,

  -- ** Async with explicit error handling
  asyncWithHandler,
  asyncWithHandler_,
  asyncWithHandlerAndUnmask,
  asyncWithHandlerAndUnmask_,

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
async :: MonadResourceManager m => ResourceManagerIO a -> m (Awaitable a)
async action = asyncWithUnmask \unmask -> unmask action

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions masked and will be passed an action that can be used to unmask.
asyncWithUnmask :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m (Awaitable r)
asyncWithUnmask action = do
  resourceManager <- askResourceManager
  asyncWithHandlerAndUnmask (throwToResourceManager resourceManager . AsyncException) action

async_ :: MonadResourceManager m => ResourceManagerIO () -> m ()
async_ action = void $ async action

asyncWithUnmask_ :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions unmasked. When an exception is thrown that is not caused from
-- the disposable instance (i.e. the task being canceled), the handler is called with that exception.
asyncWithHandlerAndUnmask :: MonadResourceManager m => (SomeException -> IO ()) -> ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m (Awaitable r)
asyncWithHandlerAndUnmask handler action = do
  resourceManager <- askResourceManager
  toAwaitable <$> registerNewResource do
    unmanagedAsyncWithHandlerAndUnmask wrappedHandler \unmask ->
      onResourceManager resourceManager (action (liftUnmask unmask))
  where
    wrappedHandler :: SomeException -> IO ()
    wrappedHandler (fromException -> Just AsyncDisposed) = pure ()
    wrappedHandler ex = handler ex
    liftUnmask :: (forall b. IO b -> IO b) -> ResourceManagerIO a -> ResourceManagerIO a
    liftUnmask unmask innerAction = do
      resourceManager <- askResourceManager
      liftIO $ unmask $ onResourceManager resourceManager innerAction

asyncWithHandlerAndUnmask_ :: MonadResourceManager m => (SomeException -> IO ()) -> ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO r) -> m ()
asyncWithHandlerAndUnmask_ handler action = void $ asyncWithHandlerAndUnmask handler action

asyncWithHandler :: MonadResourceManager m => (SomeException -> IO ()) -> ResourceManagerIO r -> m (Awaitable r)
asyncWithHandler handler action = asyncWithHandlerAndUnmask handler \unmask -> unmask action

asyncWithHandler_ :: MonadResourceManager m => (SomeException -> IO ()) -> ResourceManagerIO r -> m ()
asyncWithHandler_ handler action = void $ asyncWithHandler handler action
