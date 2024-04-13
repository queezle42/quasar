module Quasar.Async (
  Async(..),
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,
  asyncSTM,
  asyncSTM_,
  asyncWithUnmaskSTM,
  asyncWithUnmaskSTM_,

  -- ** Async exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
  isCancelAsync,
  isAsyncDisposed,

  -- ** IO variant
  async',
  asyncWithUnmask',
  asyncSTM',
  asyncWithUnmaskSTM',

  -- ** Unmanaged variants
  unmanagedAsync,
  unmanagedAsyncWithUnmask,
  unmanagedAsyncSTM,
  unmanagedAsyncWithUnmaskSTM,
) where

import Control.Concurrent (ThreadId)
import Control.Exception (throwTo)
import Control.Monad.Catch
import GHC.Stack (withFrozenCallStack)
import Quasar.Async.Fork
import Quasar.Exceptions
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Quasar.Utils.Fix


data Async a = Async (FutureEx '[AsyncException, AsyncDisposed] a) Disposer

instance Disposable (Async a) where
  getDisposer (Async _ disposer) = disposer

instance ToFuture '[AsyncException, AsyncDisposed] a (Async a) where
  toFuture (Async future _) = toFuture future


async :: (MonadQuasar m, MonadIO m, HasCallStack) => QuasarIO a -> m (Async a)
async fn = withFrozenCallStack $ asyncWithUnmask (\unmask -> unmask fn)

async_ :: (MonadQuasar m, MonadIO m, HasCallStack) => QuasarIO () -> m ()
async_ fn = withFrozenCallStack $ void $ asyncWithUnmask (\unmask -> unmask fn)

asyncWithUnmask :: (MonadQuasar m, MonadIO m, HasCallStack) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmask fn = withFrozenCallStack do
  quasar <- askQuasar
  asyncWithUnmask' (\unmask -> runQuasarIO quasar (fn (liftUnmask unmask)))
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runQuasarIO quasar innerAction

asyncWithUnmask_ :: (MonadQuasar m, MonadIO m, HasCallStack) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO ()) -> m ()
asyncWithUnmask_ fn = withFrozenCallStack $ void $ asyncWithUnmask fn


async' :: (MonadQuasar m, MonadIO m, HasCallStack) => IO a -> m (Async a)
async' fn = withFrozenCallStack $ asyncWithUnmask' (\unmask -> unmask fn)

asyncWithUnmask' :: forall a m. (MonadQuasar m, MonadIO m, HasCallStack) => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
asyncWithUnmask' fn = liftQuasarIO $ withFrozenCallStack do
  exSink <- askExceptionSink
  spawnAsync collectResource exSink fn


unmanagedAsync :: forall a m. (MonadIO m, HasCallStack) => ExceptionSink -> IO a -> m (Async a)
unmanagedAsync exSink fn = liftIO $ withFrozenCallStack do
  unmanagedAsyncWithUnmask exSink (\unmask -> unmask fn)

unmanagedAsyncWithUnmask :: forall a m. (MonadIO m, HasCallStack) => ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithUnmask exSink fn = liftIO $ withFrozenCallStack do
  spawnAsync (\_ -> pure ()) exSink fn


spawnAsync :: forall a m. (MonadIO m, MonadMask m, HasCallStack) => (Disposer -> m ()) -> ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
spawnAsync registerDisposerFn exSink fn = withFrozenCallStack $ mask_ do
  key <- liftIO newUnique
  resultVar <- newPromiseIO

  threadIdPromise <- newPromiseIO
  let threadIdFuture = toFuture threadIdPromise

  -- Disposer is created first to ensure the resource can be safely attached
  disposer <- atomically $ newUnmanagedIODisposer (disposeFn key resultVar threadIdFuture) exSink

  registerDisposerFn disposer `onException` tryFulfillPromiseIO_ threadIdPromise Nothing

  threadId <- liftIO $ forkWithUnmask (runAndPut exSink key resultVar disposer fn) exSink
  fulfillPromiseIO threadIdPromise (Just threadId)

  pure (Async (toFutureEx resultVar) disposer)
  where
    disposeFn :: Unique -> PromiseEx '[AsyncException, AsyncDisposed] a -> Future '[] (Maybe ThreadId) -> IO ()
    disposeFn key resultVar threadIdFuture = do
      -- ThreadId future will be filled after the thread is forked
      await threadIdFuture >>= mapM_ \threadId -> do
        throwTo threadId (CancelAsync key)
        -- Disposing is considered complete once a result (i.e. success or failure) has been stored
        void $ await resultVar

runAndPut :: ExceptionSink -> Unique -> PromiseEx '[AsyncException, AsyncDisposed] a -> Disposer -> ((forall b. IO b -> IO b) -> IO a) -> (forall b. IO b -> IO b) -> IO ()
runAndPut exChan key resultVar disposer fn unmask = do
  -- Called in masked state by `forkWithUnmask`
  result <- try $ fn unmask
  case result of
    Left (fromException -> Just (CancelAsync ((== key) -> True))) ->
      fulfillPromiseIO resultVar (Left (toEx AsyncDisposed))
    Left ex -> do
      atomically (throwToExceptionSink exChan ex)
        `finally` do
          fulfillPromiseIO resultVar (Left (toEx (AsyncException ex)))
          disposeEventuallyIO_ disposer
    Right retVal -> do
      fulfillPromiseIO resultVar (Right retVal)
      disposeEventuallyIO_ disposer




asyncSTM :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => QuasarIO a -> m (Async a)
asyncSTM fn = withFrozenCallStack $ asyncWithUnmaskSTM (\unmask -> unmask fn)

asyncSTM_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => QuasarIO () -> m ()
asyncSTM_ fn = withFrozenCallStack $ void do
  asyncWithUnmaskSTM (\unmask -> unmask fn)

asyncWithUnmaskSTM :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmaskSTM fn = withFrozenCallStack do
  quasar <- askQuasar
  asyncWithUnmaskSTM' (\unmask -> runQuasarIO quasar (fn (liftUnmask unmask)))
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runQuasarIO quasar innerAction

asyncWithUnmaskSTM_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO ()) -> m ()
asyncWithUnmaskSTM_ fn = withFrozenCallStack $ void $ asyncWithUnmaskSTM fn

asyncSTM' :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => IO a -> m (Async a)
asyncSTM' fn = withFrozenCallStack $ asyncWithUnmaskSTM' (\unmask -> unmask fn)

asyncWithUnmaskSTM' :: forall a m. (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
asyncWithUnmaskSTM' fn = liftQuasarSTMc @NoRetry @'[FailedToAttachResource] do
  withFrozenCallStack do
    exSink <- askExceptionSink
    x <- unmanagedAsyncWithUnmaskSTM exSink fn
    collectResource x
    pure x

unmanagedAsyncSTM :: forall a m. (MonadSTMc NoRetry '[] m, HasCallStack) => ExceptionSink -> IO a -> m (Async a)
unmanagedAsyncSTM exSink fn = withFrozenCallStack do
  unmanagedAsyncWithUnmaskSTM exSink (\unmask -> unmask fn)

unmanagedAsyncWithUnmaskSTM :: forall a m. (MonadSTMc NoRetry '[] m, HasCallStack) => ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithUnmaskSTM exSink fn = liftSTMc @NoRetry @'[] do
  withFrozenCallStack do
    key <- newUniqueSTM
    resultVar <- newPromise

    mfixExtra \threadIdFixed -> do
      disposer <- newUnmanagedIODisposer (disposeFn key resultVar threadIdFixed) exSink

      threadId <- forkWithUnmaskSTM (runAndPut exSink key resultVar disposer fn) exSink

      pure (Async (toFutureEx resultVar) disposer, threadId)
  where
    disposeFn :: Unique -> PromiseEx '[AsyncException, AsyncDisposed] a -> Future '[] ThreadId -> IO ()
    disposeFn key resultVar threadIdFuture = do
      -- ThreadId future will be filled after the thread is forked
      threadId <- await threadIdFuture
      throwTo threadId (CancelAsync key)
      -- Disposing is considered complete once a result (i.e. success or failure) has been stored
      void $ await resultVar
