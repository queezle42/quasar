module Quasar.Async (
  -- * Async/await
  MonadAsync(..),
  AsyncIO,
  async,
  await,
  awaitResult,

  -- * Task
  Task,
  cancelTask,
  cancelTaskIO,
  toTask,
  completedTask,
  successfulTask,
  failedTask,

  -- * AsyncManager
  AsyncManager,
  AsyncManagerConfiguraiton(..),
  withAsyncManager,
  withDefaultAsyncManager,
  withUnlimitedAsyncManager,
  newAsyncManager,
  defaultAsyncManagerConfiguration,
  unlimitedAsyncManagerConfiguration,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


-- | A monad for actions that run on a thread bound to a `AsyncManager`.
newtype AsyncIO a = AsyncIO (ReaderT AsyncManager IO a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask)


-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: MonadAsync m => AsyncIO r -> m (Task r)
async action = asyncWithUnmask (\unmask -> unmask action)

-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
--
-- The action will be run with asynchronous exceptions masked and will be passed an action that can be used unmask.
asyncWithUnmask :: MonadAsync m => ((forall a. AsyncIO a -> AsyncIO a) -> AsyncIO r) -> m (Task r)
-- TODO resource limits
asyncWithUnmask action = do
  asyncManager <- askAsyncManager

  liftIO $ mask_ do
    resultVar <- newAsyncVar
    threadIdVar <- newEmptyTMVarIO

    disposable <- attachDisposeAction (getResourceManager asyncManager) (disposeTask threadIdVar resultVar)

    onException
      do
        atomically . putTMVar threadIdVar . Just =<<
          forkIOWithUnmask \unmask -> do
            result <- try $ catch
              do runOnAsyncManager asyncManager (action (liftUnmask unmask))
              \CancelTask -> throwIO TaskDisposed

            putAsyncVarEither_ resultVar result

            -- Thread has completed work, "disarm" the disposable and fire it
            void $ atomically $ swapTMVar threadIdVar Nothing
            disposeIO disposable

      do atomically $ putTMVar threadIdVar Nothing

    pure $ Task disposable (toAwaitable resultVar)
  where
    disposeTask :: TMVar (Maybe ThreadId) -> AsyncVar r -> IO (Awaitable ())
    disposeTask threadIdVar resultVar = mask_ do
      -- Blocks until the thread is forked
      atomically (swapTMVar threadIdVar Nothing) >>= \case
        -- Thread completed or initialization failed
        Nothing -> pure ()
        Just threadId -> throwTo threadId CancelTask

      -- Wait for task completion or failure. Tasks must not ignore `CancelTask` or this will hang.
      pure $ mapAwaitable (const $ pure ()) resultVar

liftUnmask :: (IO a -> IO a) -> AsyncIO a -> AsyncIO a
liftUnmask unmask action = do
  asyncManager <- askAsyncManager
  liftIO $ unmask $ runOnAsyncManager asyncManager action

await :: IsAwaitable r a => a -> AsyncIO r
-- TODO resource limits
await = liftIO . awaitIO


class MonadIO m => MonadAsync m where
  askAsyncManager :: m AsyncManager

instance MonadAsync AsyncIO where
  askAsyncManager = AsyncIO ask

instance MonadIO m => MonadAsync (ReaderT AsyncManager m) where
  askAsyncManager = ask


awaitResult :: IsAwaitable r a => AsyncIO a -> AsyncIO r
awaitResult = (await =<<)

data AsyncManager = AsyncManager {
  resourceManager :: ResourceManager,
  configuration :: AsyncManagerConfiguraiton,
  threads :: TVar (HashSet ThreadId)
}

instance IsDisposable AsyncManager where
  toDisposable = toDisposable . getResourceManager

instance HasResourceManager AsyncManager where
  getResourceManager = resourceManager


-- | A task that is running asynchronously. It has a result and can fail.
-- The result (or exception) can be aquired by using the `IsAwaitable` class (e.g. by calling `await` or `awaitIO`).
-- It might be possible to cancel the task by using the `IsDisposable` class if the operation has not been completed.
-- If the result is no longer required the task should be cancelled, to avoid leaking memory.
data Task r = Task Disposable (Awaitable r)

instance IsAwaitable r (Task r) where
  toAwaitable (Task _ awaitable) = awaitable

instance IsDisposable (Task r) where
  toDisposable (Task disposable _) = disposable

instance Functor Task where
  fmap fn (Task disposable awaitable) = Task disposable (fn <$> awaitable)

instance Applicative Task where
  pure value = Task noDisposable (pure value)
  liftA2 fn (Task dx fx) (Task dy fy) = Task (dx <> dy) $ liftA2 fn fx fy

cancelTask :: Task r -> IO (Awaitable ())
cancelTask = dispose

cancelTaskIO :: Task r -> IO ()
cancelTaskIO = awaitIO <=< dispose

-- | Creates an `Task` from an `Awaitable`.
-- The resulting task only depends on an external resource, so disposing it has no effect.
toTask :: IsAwaitable r a => a -> Task r
toTask result = Task noDisposable (toAwaitable result)

completedTask :: Either SomeException r -> Task r
completedTask result = Task noDisposable (completedAwaitable result)

-- | Alias for `pure`
successfulTask :: r -> Task r
successfulTask = pure

failedTask :: SomeException -> Task r
failedTask ex = Task noDisposable (failedAwaitable ex)



data CancelTask = CancelTask
  deriving stock Show
instance Exception CancelTask where

data TaskDisposed = TaskDisposed
  deriving stock Show
instance Exception TaskDisposed where


data AsyncManagerConfiguraiton = AsyncManagerConfiguraiton {
  maxThreads :: Maybe Int
}

defaultAsyncManagerConfiguration :: AsyncManagerConfiguraiton
defaultAsyncManagerConfiguration = AsyncManagerConfiguraiton {
  maxThreads = Just 1
}

unlimitedAsyncManagerConfiguration :: AsyncManagerConfiguraiton
unlimitedAsyncManagerConfiguration = AsyncManagerConfiguraiton {
  maxThreads = Nothing
}

withAsyncManager :: AsyncManagerConfiguraiton -> AsyncIO r -> IO r
withAsyncManager configuration = bracket (newAsyncManager configuration) disposeAsyncManager . flip runOnAsyncManager

runOnAsyncManager :: AsyncManager -> AsyncIO r -> IO r
runOnAsyncManager asyncManager (AsyncIO action) = runReaderT action asyncManager

withDefaultAsyncManager :: AsyncIO a -> IO a
withDefaultAsyncManager = withAsyncManager defaultAsyncManagerConfiguration

withUnlimitedAsyncManager :: AsyncIO a -> IO a
withUnlimitedAsyncManager = withAsyncManager unlimitedAsyncManagerConfiguration

newAsyncManager :: AsyncManagerConfiguraiton -> IO AsyncManager
newAsyncManager configuration = do
  resourceManager <- newResourceManager
  threads <- newTVarIO mempty
  pure AsyncManager {
    resourceManager,
    configuration,
    threads
  }

disposeAsyncManager :: AsyncManager -> IO ()
-- TODO resource management
disposeAsyncManager = const (pure ())

