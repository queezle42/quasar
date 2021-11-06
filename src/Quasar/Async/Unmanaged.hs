module Quasar.Async.Unmanaged (
  -- ** Unmanaged variant
  Task,
  unmanagedAsync,
  unmanagedAsync_,
  unmanagedAsyncWithUnmask,
  unmanagedAsyncWithUnmask_,

  -- ** Task exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),

  -- ** Implementation internals
  coreAsyncImplementation
) where


import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, throwTo)
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
          -- Fork to prevent synchronous exceptions when disposing this thread, and to prevent blocking when disposing
          -- a thread that is running in uninterruptible masked state.
          pure $ void $ forkIO do
            throwTo threadId $ CancelAsync key
            atomically $ writeTVar stateVar TaskStateCompleted
        TaskStateThrowing -> pure $ pure @IO ()
        TaskStateCompleted -> pure $ pure @IO ()

    -- Wait for task completion or failure. Tasks must not ignore `CancelTask` or this will hang.
    pure $ DisposeResultAwait $ isDisposed self

  isDisposed (Task _ _ _ resultAwaitable) = awaitSuccessOrFailure resultAwaitable

  registerFinalizer (Task _ _ finalizers _) = defaultRegisterFinalizer finalizers

instance Functor Task where
  fmap fn (Task key actionVar finalizerVar resultAwaitable) = Task key actionVar finalizerVar (fn <$> resultAwaitable)


data CancelAsync = CancelAsync Unique
  deriving stock Eq
instance Show CancelAsync where
  show _ = "CancelAsync"
instance Exception CancelAsync where

data AsyncDisposed = AsyncDisposed
  deriving stock (Eq, Show)
instance Exception AsyncDisposed where

-- TODO Needs a descriptive name. This is similar in functionality to `ExceptionThrownInLinkedThread`
data AsyncException = AsyncException SomeException
  deriving stock Show
  deriving anyclass Exception



-- | Base implementation for the `unmanagedAsync`- and `Quasar.Async.async`-class of functions.
coreAsyncImplementation :: MonadIO m => (SomeException -> IO ()) -> ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
coreAsyncImplementation handler action = do
  liftIO $ mask_ do
    key <- newUnique
    resultVar <- newAsyncVar
    stateVar <- newTVarIO TaskStateInitializing
    finalizers <- newDisposableFinalizers

    threadId <- forkIOWithUnmask \unmask ->
      handleAll
        do \ex -> fail $ "coreAsyncImplementation thread failed: " <> displayException ex
        do
          result <- try $ catchAll
            do action unmask
            \ex -> do
              -- Rewrite exception if its the cancel exception for this async
              when (fromException ex == Just (CancelAsync key)) $ throwIO AsyncDisposed
              throwIO $ AsyncException ex

          -- The `action` has completed its work.
          -- "disarm" dispose:
          catchIf
            do \(CancelAsync exKey) -> key == exKey
            do
              atomically $ readTVar stateVar >>= \case
                TaskStateInitializing -> retry
                TaskStateRunning _ -> writeTVar stateVar TaskStateCompleted
                TaskStateThrowing -> retry -- Could not disarm so we have to wait for the exception to arrive
                TaskStateCompleted -> pure ()
            do mempty -- ignore exception if it matches; this can only happen once (see TaskStateThrowing above)

          catchAll
            case result of
              Left (fromException -> Just AsyncDisposed) -> pure ()
              Left ex -> handler ex
              _ -> pure ()
            \ex -> traceIO $ "An exception was thrown while handling an async exception: " <> displayException ex

          atomically do
            putAsyncVarEitherSTM_ resultVar result
            defaultRunFinalizers finalizers

    atomically $ writeTVar stateVar $ TaskStateRunning threadId

    pure $ Task key stateVar finalizers (toAwaitable resultVar)


unmanagedAsync :: MonadIO m => IO a -> m (Task a)
unmanagedAsync action = unmanagedAsyncWithUnmask \unmask -> unmask action

unmanagedAsync_ :: MonadIO m => IO () -> m Disposable
unmanagedAsync_ action = toDisposable <$> unmanagedAsync action

unmanagedAsyncWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
unmanagedAsyncWithUnmask = coreAsyncImplementation (traceIO . ("Unhandled exception in unmanaged async: " <>) . displayException)

unmanagedAsyncWithUnmask_ :: MonadIO m => ((forall b. IO b -> IO b) -> IO ()) -> m Disposable
unmanagedAsyncWithUnmask_ action = toDisposable <$> unmanagedAsyncWithUnmask action
