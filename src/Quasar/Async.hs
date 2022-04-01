module Quasar.Async (
  Async,
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
) where

import Control.Concurrent (ThreadId)
import Control.Monad.Catch
import Quasar.Async.Fork
import Quasar.Future
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Control.Monad.Reader
import Control.Exception (throwTo)


data Async a = Async (Future a) Disposer

instance Resource (Async a) where
  getDisposer (Async _ disposer) = [disposer]

instance IsFuture a (Async a) where
  toFuture (Async awaitable _) = awaitable


async :: (MonadQuasar m, MonadIO m) => QuasarIO a -> m (Async a)
async fn = asyncWithUnmask ($ fn)

async_ :: (MonadQuasar m, MonadIO m) => QuasarIO () -> m ()
async_ fn = void $ asyncWithUnmask ($ fn)

asyncWithUnmask :: (MonadQuasar m, MonadIO m) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmask fn = do
  quasar <- askQuasar
  asyncWithUnmask' (\unmask -> runReaderT (fn (liftUnmask unmask)) quasar)
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runReaderT innerAction quasar

asyncWithUnmask_ :: (MonadQuasar m, MonadIO m) => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO ()) -> m ()
asyncWithUnmask_ fn = void $ asyncWithUnmask fn


async' :: (MonadQuasar m, MonadIO m) => IO a -> m (Async a)
async' fn = asyncWithUnmask' ($ fn)

asyncWithUnmask' :: forall a m. (MonadQuasar m, MonadIO m) => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
asyncWithUnmask' fn = liftQuasarIO do
  exChan <- askExceptionSink

  key <- liftIO newUnique
  resultVar <- newPromise

  afixExtra \threadIdFuture -> mask_ do

    -- Disposer is created first to ensure the resource can be safely attached
    disposer <- registerDisposeAction (disposeFn key resultVar threadIdFuture)

    threadId <- liftIO $ forkWithUnmask (runAndPut exChan key resultVar disposer) exChan

    pure (Async (toFuture resultVar) disposer, threadId)
  where
    runAndPut :: ExceptionSink -> Unique -> Promise a -> Disposer -> (forall b. IO b -> IO b) -> IO ()
    runAndPut exChan key resultVar disposer unmask = do
      -- Called in masked state by `forkWithUnmask`
      result <- try $ fn unmask
      case result of
        Left (fromException -> Just (CancelAsync ((== key) -> True))) ->
          breakPromise resultVar AsyncDisposed
        Left ex -> do
          atomically (throwToExceptionSink exChan ex)
            `finally` do
              breakPromise resultVar (AsyncException ex)
              atomically $ disposeEventuallySTM_ disposer
        Right retVal -> do
          fulfillPromise resultVar retVal
          atomically $ disposeEventuallySTM_ disposer
    disposeFn :: Unique -> Promise a -> Future ThreadId -> IO ()
    disposeFn key resultVar threadIdFuture = do
      -- Should not block or fail (unless the TIOWorker is broken)
      threadId <- await threadIdFuture
      throwTo threadId (CancelAsync key)
      -- Disposing is considered complete once a result (i.e. success or failure) has been stored
      awaitSuccessOrFailure resultVar
