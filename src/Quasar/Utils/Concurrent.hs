module Quasar.Utils.Concurrent (
  Task,
  unmanagedFork,
  unmanagedFork_,
  unmanagedForkWithUnmask,
  unmanagedForkWithUnmask_,

  -- ** Task exceptions
  CancelTask(..),
  TaskDisposed(..),
)where


import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude




-- | A task is an operation (e.g. a thread or a network request) that is running asynchronously and can be cancelled.
-- It has a result and can fail.
--
-- The result (or exception) can be aquired by using the `IsAwaitable` class (e.g. by calling `await` or `awaitIO`).
-- It is possible to cancel the task by using `dispose` or `cancelTask` if the operation has not been completed.
data Task r = Task Unique (TVar TaskState) DisposableFinalizers (Awaitable r)

data TaskState = TaskStateInitializing | TaskStateRunning ThreadId | TaskStateThrowing | TaskStateCompleted

instance IsAwaitable r (Task r) where
  toAwaitable (Task _ _ _ resultAwaitable) = resultAwaitable

instance IsDisposable (Task r) where
  beginDispose self@(Task key stateVar _ _) = uninterruptibleMask_ do
    join $ atomically do
      readTVar stateVar >>= \case
        TaskStateInitializing -> unreachableCodePathM
        TaskStateRunning threadId -> do
          writeTVar stateVar TaskStateThrowing
          pure do
            throwTo threadId $ CancelTask key
            atomically $ writeTVar stateVar TaskStateCompleted
        TaskStateThrowing -> pure $ pure ()
        TaskStateCompleted -> pure $ pure ()

    -- Wait for task completion or failure. Tasks must not ignore `CancelTask` or this will hang.
    pure $ DisposeResultAwait $ isDisposed self

  isDisposed (Task _ _ _ resultAwaitable) = (() <$ resultAwaitable) `catchAll` \_ -> pure ()

  registerFinalizer (Task _ _ finalizers _) = defaultRegisterFinalizer finalizers

instance Functor Task where
  fmap fn (Task key actionVar finalizerVar resultAwaitable) = Task key actionVar finalizerVar (fn <$> resultAwaitable)


data CancelTask = CancelTask Unique
instance Show CancelTask where
  show _ = "CancelTask"
instance Exception CancelTask where

data TaskDisposed = TaskDisposed
  deriving stock Show
instance Exception TaskDisposed where





unmanagedFork :: MonadIO m => IO a -> m (Task a)
unmanagedFork action = unmanagedForkWithUnmask \unmask -> unmask action

unmanagedFork_ :: MonadIO m => IO () -> m Disposable
unmanagedFork_ action = toDisposable <$> unmanagedFork action

unmanagedForkWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
unmanagedForkWithUnmask action = do
  liftIO $ mask_ do
    key <- newUnique
    resultVar <- newAsyncVar
    stateVar <- newTVarIO TaskStateInitializing
    finalizers <- newDisposableFinalizers

    threadId <- forkIOWithUnmask \unmask ->
      handleAll
        do \ex -> fail $ "unmanagedForkWithUnmask thread failed: " <> displayException ex
        do
          result <- try $ handleIf
            do \(CancelTask exKey) -> key == exKey
            do \_ -> throwIO TaskDisposed
            do
              action unmask

          -- The `action` has completed its work.
          -- "disarm" dispose:
          handleIf
            do \(CancelTask exKey) -> key == exKey
            do mempty -- ignore exception if it matches; this can only happen once
            do
              atomically $ readTVar stateVar >>= \case
                TaskStateInitializing -> retry
                TaskStateRunning _ -> writeTVar stateVar TaskStateCompleted
                TaskStateThrowing -> retry -- Could not disarm so we have to wait for the exception to arrive
                TaskStateCompleted -> pure ()

          atomically do
            putAsyncVarEitherSTM_ resultVar result
            defaultRunFinalizers finalizers


    atomically $ writeTVar stateVar $ TaskStateRunning threadId

    pure $ Task key stateVar finalizers (toAwaitable resultVar)

unmanagedForkWithUnmask_ :: MonadIO m => ((forall b. IO b -> IO b) -> IO ()) -> m Disposable
unmanagedForkWithUnmask_ action = toDisposable <$> unmanagedForkWithUnmask action
