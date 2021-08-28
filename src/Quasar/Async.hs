module Quasar.Async (
  -- * Async/await
  MonadAsync(..),
  async,

  -- * Task
  Task,
  cancelTask,
  cancelTaskIO,
  toTask,
  completedTask,
  successfulTask,
  failedTask,

  -- ** Task exceptions
  CancelTask(..),
  TaskDisposed(..),
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


class (MonadAwait m, MonadResourceManager m, MonadCatch m) => MonadAsync m where
  -- | TODO
  async :: m r -> m (Task r)
  async action = asyncWithUnmask ($ action)

  -- | TODO
  --
  -- The action will be run with asynchronous exceptions masked and will be passed an action that can be used unmask.
  asyncWithUnmask :: ((forall a. m a -> m a) -> m r) -> m (Task r)

instance MonadAsync (ReaderT ResourceManager IO) where
  asyncWithUnmask action = do
    resourceManager <- askResourceManager

    liftIO $ mask_ do
      resultVar <- newAsyncVar
      threadIdVar <- newEmptyTMVarIO

      disposable <- attachDisposeAction resourceManager (disposeTask threadIdVar resultVar)

      onException
        do
          atomically . putTMVar threadIdVar . Just =<<
            forkIOWithUnmask \unmask -> do
              result <- try $ catch
                do runReaderT (action (liftUnmask unmask)) resourceManager
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
        pure $ void (toAwaitable resultVar) `catchAll` const (pure ())

      liftUnmask :: (IO a -> IO a) -> (ReaderT ResourceManager IO) a -> (ReaderT ResourceManager IO) a
      liftUnmask unmask action = do
        resourceManager <- askResourceManager
        liftIO $ unmask $ runReaderT action resourceManager



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
cancelTaskIO = await <=< dispose

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
