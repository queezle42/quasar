module Quasar.Async (
  Async(..),
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,

  -- ** Async exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
  isCancelAsync,
  isAsyncDisposed,

  -- ** IO variant
  async',
  asyncWithUnmask',

  -- ** Unmanaged variants
  unmanagedAsync,
  unmanagedAsyncWithUnmask,
) where

import Control.Concurrent (ThreadId)
import Control.Monad.Catch
import Quasar.Async.Fork
import Quasar.Future
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Control.Exception (throwTo)


data Async a = Async (FutureEx '[AsyncException, AsyncDisposed] a) Disposer

instance Disposable (Async a) where
  getDisposer (Async _ disposer) = disposer

instance ToFuture (Either (Ex '[AsyncException, AsyncDisposed]) a) (Async a) where
  toFuture (Async future _) = toFuture future


async :: (MonadQuasar m, MonadIO m) => QuasarIO a -> m (Async a)
async fn = asyncWithUnmask (\unmask -> unmask fn)

async_ :: (MonadQuasar m, MonadIO m) => QuasarIO () -> m ()
async_ fn = void $ asyncWithUnmask (\unmask -> unmask fn)

asyncWithUnmask :: (MonadQuasar m, MonadIO m) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmask fn = do
  quasar <- askQuasar
  asyncWithUnmask' (\unmask -> runQuasarIO quasar (fn (liftUnmask unmask)))
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runQuasarIO quasar innerAction

asyncWithUnmask_ :: (MonadQuasar m, MonadIO m) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO ()) -> m ()
asyncWithUnmask_ fn = void $ asyncWithUnmask fn


async' :: (MonadQuasar m, MonadIO m) => IO a -> m (Async a)
async' fn = asyncWithUnmask' (\unmask -> unmask fn)

asyncWithUnmask' :: forall a m. (MonadQuasar m, MonadIO m) => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
asyncWithUnmask' fn = liftQuasarIO do
  exSink <- askExceptionSink
  spawnAsync collectResource exSink fn


unmanagedAsync :: forall a m. MonadIO m => ExceptionSink -> IO a -> m (Async a)
unmanagedAsync exSink fn = liftIO $ unmanagedAsyncWithUnmask exSink (\unmask -> unmask fn)

unmanagedAsyncWithUnmask :: forall a m. MonadIO m => ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithUnmask exSink fn = liftIO $ spawnAsync (\_ -> pure ()) exSink fn


spawnAsync :: forall a m. (MonadIO m, MonadMask m) => (Disposer -> m ()) -> ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
spawnAsync registerDisposerFn exSink fn = mask_ do
  key <- liftIO newUnique
  resultVar <- newPromiseIO

  threadIdPromise <- newPromiseIO
  let threadIdFuture = toFuture threadIdPromise

  -- Disposer is created first to ensure the resource can be safely attached
  disposer <- atomically $ newUnmanagedIODisposer (disposeFn key resultVar threadIdFuture) exSink

  registerDisposerFn disposer

  threadId <- liftIO $ forkWithUnmask (runAndPut exSink key resultVar disposer) exSink
  fulfillPromiseIO threadIdPromise threadId

  pure (Async (toFutureEx resultVar) disposer)
  where
    runAndPut :: ExceptionSink -> Unique -> PromiseEx '[AsyncException, AsyncDisposed] a -> Disposer -> (forall b. IO b -> IO b) -> IO ()
    runAndPut exChan key resultVar disposer unmask = do
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
    disposeFn :: Unique -> PromiseEx '[AsyncException, AsyncDisposed] a -> Future ThreadId -> IO ()
    disposeFn key resultVar threadIdFuture = do
      -- ThreadId future will be filled after the thread is forked
      threadId <- await threadIdFuture
      throwTo threadId (CancelAsync key)
      -- Disposing is considered complete once a result (i.e. success or failure) has been stored
      void $ await resultVar
