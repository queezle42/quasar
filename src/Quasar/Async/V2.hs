module Quasar.Async.V2 (
  Async,
  async,
  asyncWithUnmask,

  -- ** Async exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
  isCancelAsync,
  isAsyncDisposed,

  -- ** Unmanaged variants
  unmanagedAsync,
  unmanagedAsyncWithUnmask,
) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Monad
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO
import Control.Monad.Reader


data Async a = Async (Awaitable a) Disposer

instance Resource (Async a) where
  getDisposer (Async _ disposer) = disposer

instance IsAwaitable a (Async a) where
  toAwaitable (Async awaitable _) = awaitable


unmanagedAsync :: IO a -> TIOWorker -> ExceptionChannel -> STM (Async a)
unmanagedAsync fn = unmanagedAsyncWithUnmask (\unmask -> unmask fn)

unmanagedAsyncWithUnmask :: forall a. ((forall b. IO b -> IO b) -> IO a) -> TIOWorker -> ExceptionChannel -> STM (Async a)
unmanagedAsyncWithUnmask fn worker exChan = do
  key <- newUniqueSTM
  resultVar <- newAsyncVarSTM
  disposer <- mfix \disposer -> do
    tidAwaitable <- forkWithUnmask (runAndPut key resultVar disposer) worker exChan
    newPrimitiveDisposer (disposeFn key resultVar tidAwaitable) worker exChan
  pure $ Async (toAwaitable resultVar) disposer
  where
    runAndPut :: Unique -> AsyncVar a -> Disposer -> (forall b. IO b -> IO b) -> IO ()
    runAndPut key resultVar disposer unmask = do
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
    disposeFn key resultVar tidAwaitable = do
      -- Awaits forking of the thread, which should happen immediately (as long as the TIOWorker-invariant isn't broken elsewhere)
      tid <- unsafeShortIO $ await tidAwaitable
      -- `throwTo` should also happen immediately, as long as `uninterruptibleMask` isn't abused elsewhere
      throwToShortIO tid (CancelAsync key)
      -- Considered complete once a result (i.e. success or failure) has been stored
      pure (() <$ toAwaitable resultVar)


async :: MonadQuasar m => QuasarIO a -> m (Async a)
async fn = asyncWithUnmask ($ fn)

asyncWithUnmask :: MonadQuasar m => ((forall b. QuasarIO b -> QuasarIO b) -> QuasarIO a) -> m (Async a)
asyncWithUnmask fn = do
  quasar <- askQuasar
  worker <- askIOWorker
  exChan <- askExceptionChannel
  rm <- askResourceManager
  runSTM do
    as <- unmanagedAsyncWithUnmask (\unmask -> runReaderT (fn (liftUnmask unmask)) quasar) worker exChan
    attachResource rm as
    pure as
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runReaderT innerAction quasar
