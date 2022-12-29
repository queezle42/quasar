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
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Control.Exception (throwTo)


data Async a = Async (FutureE a) Disposer

instance Resource (Async a) where
  toDisposer (Async _ disposer) = disposer

instance IsFuture (Either SomeException a) (Async a) where
  toFuture (Async futureE _) = toFuture futureE


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
  worker <- askIOWorker
  exSink <- askExceptionSink
  spawnAsync registerResourceIO worker exSink fn


unmanagedAsync :: forall a m. MonadIO m => TIOWorker -> ExceptionSink -> IO a -> m (Async a)
unmanagedAsync worker exSink fn = liftIO $ unmanagedAsyncWithUnmask worker exSink (\unmask -> unmask fn)

unmanagedAsyncWithUnmask :: forall a m. MonadIO m => TIOWorker -> ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
unmanagedAsyncWithUnmask worker exSink fn = liftIO $ spawnAsync (\_ -> pure ()) worker exSink fn


spawnAsync :: forall a m. (MonadIO m, MonadMask m) => (Disposer -> m ()) -> TIOWorker -> ExceptionSink -> ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
spawnAsync registerDisposerFn worker exSink fn = do
  key <- liftIO newUnique
  resultVar <- newPromise

  afixExtra \threadIdFuture -> mask_ do

    -- Disposer is created first to ensure the resource can be safely attached
    disposer <- atomically $ newUnmanagedIODisposer (disposeFn key resultVar threadIdFuture) worker exSink

    registerDisposerFn disposer

    threadId <- liftIO $ forkWithUnmask (runAndPut exSink key resultVar disposer) exSink

    pure (Async (toFutureE resultVar) disposer, threadId)
  where
    runAndPut :: ExceptionSink -> Unique -> PromiseE a -> Disposer -> (forall b. IO b -> IO b) -> IO ()
    runAndPut exChan key resultVar disposer unmask = do
      -- Called in masked state by `forkWithUnmask`
      result <- try $ fn unmask
      case result of
        Left (fromException -> Just (CancelAsync ((== key) -> True))) ->
          fulfillPromise resultVar (Left (toException AsyncDisposed))
        Left ex -> do
          atomically (throwToExceptionSink exChan ex)
            `finally` do
              fulfillPromise resultVar (Left (toException (AsyncException ex)))
              disposeEventuallyIO_ disposer
        Right retVal -> do
          fulfillPromise resultVar (Right retVal)
          disposeEventuallyIO_ disposer
    disposeFn :: Unique -> PromiseE a -> FutureE ThreadId -> IO ()
    disposeFn key resultVar threadIdFuture = do
      -- ThreadId future will be filled by afix
      threadId <- either throwM pure =<< await threadIdFuture
      throwTo threadId (CancelAsync key)
      -- Disposing is considered complete once a result (i.e. success or failure) has been stored
      void $ await resultVar
