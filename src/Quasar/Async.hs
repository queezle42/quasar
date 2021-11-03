module Quasar.Async (
  -- * Async
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,

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
  toAwaitable <$> registerNewResource do
    coreAsyncImplementation (handler resourceManager) \unmask ->
      onResourceManager resourceManager (action (liftUnmask unmask))
  where
    handler :: ResourceManager -> SomeException -> IO ()
    handler resourceManager ex = when (fromException ex /= Just AsyncDisposed) do
      -- Throwing to the resource manager is safe because the handler runs on the async thread the resource manager
      -- cannot reach disposed state until the thread exits
      throwToResourceManager resourceManager ex
    liftUnmask :: (forall b. IO b -> IO b) -> ResourceManagerIO a -> ResourceManagerIO a
    liftUnmask unmask innerAction = do
      resourceManager <- askResourceManager
      liftIO $ unmask $ onResourceManager resourceManager innerAction

async_ :: MonadResourceManager m => (ResourceManagerIO ()) -> m ()
async_ action = void $ async action

asyncWithUnmask_ :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action
