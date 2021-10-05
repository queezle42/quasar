module Quasar.Utils.Concurrent (
  unmanagedFork,
  unmanagedFork_,
  unmanagedForkWithUnmask,
  unmanagedForkWithUnmask_,
)where


import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


unmanagedFork :: MonadIO m => IO a -> m (Task a)
unmanagedFork action = unmanagedForkWithUnmask \unmask -> unmask action

unmanagedFork_ :: MonadIO m => IO () -> m Disposable
unmanagedFork_ action = toDisposable <$> unmanagedFork action

unmanagedForkWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
unmanagedForkWithUnmask action = do
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

            -- The `action` has completed its work.
            -- "disarm" the disposer thread ...
            void $ atomically $ swapTMVar threadIdVar Nothing
            -- .. then fire the disposable to release resources (the disposer thread) and to signal that this thread is
            -- disposed.
            await =<< dispose disposable

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

unmanagedForkWithUnmask_ :: MonadIO m => ((forall b. IO b -> IO b) -> IO ()) -> m Disposable
unmanagedForkWithUnmask_ action = toDisposable <$> unmanagedForkWithUnmask action
