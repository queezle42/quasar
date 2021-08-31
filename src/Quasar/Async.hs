module Quasar.Async (
  -- * Async/await
  MonadAsync(..),
  runUnlimitedAsync,
  async_,
  asyncWithUnmask_,

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

  -- * Unmanaged forking
  forkTask,
  forkTask_,
  forkTaskWithUnmask,
  forkTaskWithUnmask_,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


class (MonadAwait m, MonadResourceManager m) => MonadAsync m where
  async :: m r -> m (Awaitable r)
  async action = asyncWithUnmask ($ action)

  -- | TODO: Documentation
  --
  -- The action will be run with asynchronous exceptions masked and will be passed an action that can be used unmask.
  --
  -- TODO change signature to `Awaitable`
  asyncWithUnmask :: ((forall a. m a -> m a) -> m r) -> m (Awaitable r)


instance MonadAsync m => MonadAsync (ReaderT r m) where
  asyncWithUnmask :: MonadAsync m => ((forall b. ReaderT r m b -> ReaderT r m b) -> ReaderT r m a) -> ReaderT r m (Awaitable a)
  asyncWithUnmask action = do
    x <- ask
    lift $ asyncWithUnmask \unmask -> runReaderT (action (liftUnmask unmask)) x
    where
      -- | Lift an "unmask" action (e.g. from `mask`) into a `ReaderT`.
      liftUnmask :: (m a -> m a) -> (ReaderT r m) a -> (ReaderT r m) a
      liftUnmask unmask action = do
        value <- ask
        lift $ unmask $ runReaderT action value


async_ :: MonadAsync m => m () -> m ()
async_ = void . async

asyncWithUnmask_ :: MonadAsync m => ((forall a. m a -> m a) -> m ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action



newtype UnlimitedAsync r = UnlimitedAsync { unUnlimitedAsync :: (ReaderT ResourceManager IO r) }
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadIO,
    MonadThrow,
    MonadCatch,
    MonadMask,
    MonadFail,
    Alternative,
    MonadPlus,
    MonadAwait,
    MonadResourceManager
  )

instance MonadAsync UnlimitedAsync where
  asyncWithUnmask action = do
    resourceManager <- askResourceManager
    liftIO $ mask_ $ do
      task <- forkTaskWithUnmask (\unmask -> runReaderT (unUnlimitedAsync (action (liftUnmask unmask))) resourceManager)
      attachDisposable resourceManager task
      pure $ toAwaitable task
    where
      liftUnmask :: (forall b. IO b -> IO b) -> UnlimitedAsync a -> UnlimitedAsync a
      liftUnmask unmask (UnlimitedAsync action) = UnlimitedAsync do
        resourceManager <- ask
        liftIO $ unmask $ runReaderT action resourceManager


runUnlimitedAsync :: (MonadResourceManager m) => (forall f. MonadAsync f => f r) -> m r
runUnlimitedAsync action = do
  resourceManager <- askResourceManager
  liftIO $ runReaderT (unUnlimitedAsync action) resourceManager



forkTask :: MonadIO m => IO a -> m (Task a)
forkTask action = forkTaskWithUnmask ($ action)

forkTask_ :: MonadIO m => IO () -> m Disposable
forkTask_ action = toDisposable <$> forkTask action

forkTaskWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
forkTaskWithUnmask action = do
  liftIO $ mask_ do
    resultVar <- newAsyncVar
    threadIdVar <- newEmptyTMVarIO

    disposable <- newDisposable $ disposeTask threadIdVar resultVar

    onException
      do
        atomically . putTMVar threadIdVar . Just =<<
          forkIOWithUnmask \unmask -> do
            result <- try $ catch
              do action unmask
              \CancelTask -> throwIO TaskDisposed

            putAsyncVarEither_ resultVar result

            -- Thread has completed work, "disarm" the disposable and fire it
            void $ atomically $ swapTMVar threadIdVar Nothing
            disposeAndAwait disposable

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

forkTaskWithUnmask_ :: MonadIO m => ((forall b. IO b -> IO b) -> IO ()) -> m Disposable
forkTaskWithUnmask_ action = toDisposable <$> forkTaskWithUnmask action




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
