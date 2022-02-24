module Quasar.Async.V2 (
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
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Async.Fork
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Monad
import Quasar.Prelude
import Quasar.Resources
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO
import Control.Monad.Reader


data Async a = Async (Awaitable a) Disposer

instance Resource (Async a) where
  getDisposer (Async _ disposer) = disposer

instance IsAwaitable a (Async a) where
  toAwaitable (Async awaitable _) = awaitable


async :: MonadQuasar m => QuasarIO a -> m (Async a)
async fn = asyncWithUnmask ($ fn)

async_ :: MonadQuasar m => QuasarIO () -> m ()
async_ fn = void $ asyncWithUnmask ($ fn)

asyncWithUnmask :: MonadQuasar m => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmask fn = do
  quasar <- askQuasar
  asyncWithUnmask' (\unmask -> runReaderT (fn (liftUnmask unmask)) quasar)
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runReaderT innerAction quasar

asyncWithUnmask_ :: MonadQuasar m => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO ()) -> m ()
asyncWithUnmask_ fn = void $ asyncWithUnmask fn


async' :: MonadQuasar m => IO a -> m (Async a)
async' fn = asyncWithUnmask' ($ fn)

asyncWithUnmask' :: forall a m. MonadQuasar m => ((forall b. IO b -> IO b) -> IO a) -> m (Async a)
asyncWithUnmask' fn = maskIfRequired do
  worker <- askIOWorker
  exChan <- askExceptionChannel

  (key, resultVar, threadIdVar, disposer) <- ensureSTM do
    key <- newUniqueSTM
    resultVar <- newAsyncVarSTM
    threadIdVar <- newAsyncVarSTM
    -- Disposer is created first to ensure the resource can be safely attached
    disposer <- newUnmanagedPrimitiveDisposer (disposeFn key resultVar (toAwaitable threadIdVar)) worker exChan
    pure (key, resultVar, threadIdVar, disposer)

  registerResource disposer

  startShortIO_ do
    threadId <- forkWithUnmaskShortIO (runAndPut exChan key resultVar disposer) exChan
    putAsyncVarShortIO_ threadIdVar threadId

  pure $ Async (toAwaitable resultVar) disposer
  where
    runAndPut :: ExceptionChannel -> Unique -> AsyncVar a -> Disposer -> (forall b. IO b -> IO b) -> IO ()
    runAndPut exChan key resultVar disposer unmask = do
      -- Called in masked state by `forkWithUnmask`
      result <- try $ fn unmask
      case result of
        Left (fromException -> Just (CancelAsync ((== key) -> True))) ->
          failAsyncVar_ resultVar AsyncDisposed
        Left ex -> do
          atomically (throwToExceptionChannel exChan ex)
            `finally` do
              failAsyncVar_ resultVar (AsyncException ex)
              atomically $ disposeEventuallySTM_ disposer
        Right retVal -> do
          putAsyncVar_ resultVar retVal
          atomically $ disposeEventuallySTM_ disposer
    disposeFn :: Unique -> AsyncVar a -> Awaitable ThreadId -> ShortIO (Awaitable ())
    disposeFn key resultVar threadIdAwaitable = do
      -- Should not block or fail (unless the TIOWorker is broken)
      threadId <- unsafeShortIO $ await threadIdAwaitable
      throwToShortIO threadId (CancelAsync key)
      -- Considered complete once a result (i.e. success or failure) has been stored
      pure (awaitSuccessOrFailure resultVar)
