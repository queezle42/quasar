module Quasar.Async (
  -- * Async/await
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,
) where

import Control.Monad.Reader
import Quasar.Awaitable
import Quasar.Prelude
import Quasar.ResourceManager
import Quasar.Utils.Concurrent


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
    unmanagedForkWithUnmask (\unmask -> runReaderT (action (liftUnmask unmask)) resourceManager)
  where
    liftUnmask :: (forall b. IO b -> IO b) -> ResourceManagerIO a -> ResourceManagerIO a
    liftUnmask unmask innerAction = do
      resourceManager <- askResourceManager
      liftIO $ unmask $ runReaderT innerAction resourceManager

async_ :: MonadResourceManager m => (ResourceManagerIO ()) -> m ()
async_ action = void $ async action

asyncWithUnmask_ :: MonadResourceManager m => ((ResourceManagerIO a -> ResourceManagerIO a) -> ResourceManagerIO ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action
