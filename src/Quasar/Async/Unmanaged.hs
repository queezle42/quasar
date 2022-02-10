module Quasar.Async.Unmanaged (
  -- ** Unmanaged variant
  Async,
  unmanagedAsync,
  unmanagedAsyncWithHandler,
  unmanagedAsyncWithUnmask,
  unmanagedAsyncWithHandlerAndUnmask,

  -- ** Async exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
  isCancelAsync,
  isAsyncDisposed,
) where


import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Exceptions
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


-- | A async is an asynchronously running computation that can be cancelled.
--
-- The result (or exception) can be aquired by using the `IsAwaitable` class (e.g. by calling `await` or `awaitIO`).
-- It is possible to cancel the async by using `dispose` if the operation has not been completed.
data Async r = Async Unique (TVar AsyncState) DisposableFinalizers (Awaitable r)

data AsyncState = AsyncStateInitializing | AsyncStateRunning ThreadId | AsyncStateThrowing | AsyncStateCompleted

instance IsAwaitable r (Async r) where
  toAwaitable (Async _ _ _ resultAwaitable) = resultAwaitable

instance IsDisposable (Async r) where
  beginDispose self@(Async key stateVar _ _) = uninterruptibleMask_ do
    join $ atomically do
      readTVar stateVar >>= \case
        AsyncStateInitializing -> unreachableCodePathM
        AsyncStateRunning threadId -> do
          writeTVar stateVar AsyncStateThrowing
          -- Fork to prevent synchronous exceptions when disposing this thread, and to prevent blocking when disposing
          -- a thread that is running in uninterruptible masked state.
          pure $ void $ forkIO do
            throwTo threadId $ CancelAsync key
            atomically $ writeTVar stateVar AsyncStateCompleted
        AsyncStateThrowing -> pure $ pure @IO ()
        AsyncStateCompleted -> pure $ pure @IO ()

    -- Wait for async completion or failure. Asyncs must not ignore `CancelAsync` or this will hang.
    pure $ DisposeResultAwait $ isDisposed self

  isDisposed (Async _ _ _ resultAwaitable) = awaitSuccessOrFailure resultAwaitable

  registerFinalizer (Async _ _ finalizers _) = defaultRegisterFinalizer finalizers

instance Functor Async where
  fmap fn (Async key actionVar finalizerVar resultAwaitable) = Async key actionVar finalizerVar (fn <$> resultAwaitable)



-- | Base implementation for the `unmanagedAsync`- and `Quasar.Async.async`-class of functions.
unmanagedAsyncWithHandlerAndUnmask :: MonadIO m => (SomeException -> IO ()) -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithHandlerAndUnmask handler action = do
  liftIO $ mask_ do
    key <- newUnique
    resultVar <- newAsyncVar
    stateVar <- newTVarIO AsyncStateInitializing
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
                AsyncStateInitializing -> retry
                AsyncStateRunning _ -> writeTVar stateVar AsyncStateCompleted
                AsyncStateThrowing -> retry -- Could not disarm so we have to wait for the exception to arrive
                AsyncStateCompleted -> pure ()
            do mempty -- ignore exception if it matches; this can only happen once (see AsyncStateThrowing above)

          catchAll
            case result of
              Left (fromException -> Just AsyncDisposed) -> pure ()
              Left (fromException -> Just (AsyncException ex)) -> handler ex
              -- Impossible code path reached
              Left ex -> traceIO $ "Error in unmanagedAsyncWithHandlerAndUnmask: " <> displayException ex
              _ -> pure ()
            \ex -> traceIO $ "An exception was thrown while handling an async exception: " <> displayException ex

          atomically do
            putAsyncVarEitherSTM_ resultVar result
            defaultRunFinalizers finalizers

    atomically $ writeTVar stateVar $ AsyncStateRunning threadId

    pure $ Async key stateVar finalizers (toAwaitable resultVar)


unmanagedAsync :: MonadIO m => IO a -> m (Async a)
unmanagedAsync action = unmanagedAsyncWithUnmask \unmask -> unmask action

unmanagedAsyncWithHandler :: MonadIO m => (SomeException -> IO ()) -> IO a -> m (Async a)
unmanagedAsyncWithHandler handler action = unmanagedAsyncWithHandlerAndUnmask handler \unmask -> unmask action

unmanagedAsyncWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithUnmask = unmanagedAsyncWithHandlerAndUnmask (traceIO . ("Unhandled exception in unmanaged async: " <>) . displayException)


-- | Run a computation concurrently to another computation. When the current thread leaves `withAsync`, the async
-- computation is cancelled.
--
-- While the async is disposed when `withUnmanagedAsync` exits, an exception would be ignored if the action fails. This
-- behavior is similar to the @withAsync@ function from the @async@ package.
--
-- For an exception-safe version, see `Quasar.Async.withAsync`.
withUnmanagedAsync :: (MonadIO m, MonadMask m) => IO r -> (Async r -> m a) -> m a
withUnmanagedAsync action = bracket (unmanagedAsync action) dispose
