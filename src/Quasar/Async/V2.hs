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
import Control.Exception (throwTo)
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Monad
import Quasar.Prelude
import Quasar.Resources.Disposer
import Control.Monad.Reader


data Async a = Async (Awaitable a) Disposer

instance Resource (Async a) where
  getDisposer (Async _ disposer) = disposer

instance IsAwaitable a (Async a) where
  toAwaitable (Async awaitable _) = awaitable


unmanagedAsync :: TIOWorker -> ExceptionChannel -> IO a -> STM (Async a)
unmanagedAsync worker exChan fn = unmanagedAsyncWithUnmask worker exChan \unmask -> unmask fn

unmanagedAsyncWithUnmask :: forall a. TIOWorker -> ExceptionChannel -> ((forall b. IO b -> IO b) -> IO a) -> STM (Async a)
unmanagedAsyncWithUnmask worker exChan fn = do
  key <- newUniqueSTM
  resultVar <- newAsyncVarSTM
  disposer <- mfix \disposer -> do
    tidAwaitable <- forkWithUnmask worker exChan (runAndPut key resultVar disposer)
    newPrimitiveDisposer worker exChan (disposeFn key resultVar tidAwaitable)
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
    disposeFn :: Unique -> AsyncVar a -> Awaitable ThreadId -> IO (Awaitable ())
    disposeFn key resultVar tidAwaitable = do
      -- Awaits forking of the thread, which should happen immediately (as long as the TIOWorker-invariant isn't broken elsewhere)
      tid <- await tidAwaitable
      -- `throwTo` should also happen immediately, as long as `uninterruptibleMask` isn't abused elsewhere
      throwTo tid (CancelAsync key)
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
    as <- unmanagedAsyncWithUnmask worker exChan \unmask -> runReaderT (fn (liftUnmask unmask)) quasar
    attachResource rm as
    pure as
  where
    liftUnmask :: (forall b. IO b -> IO b) -> QuasarIO a -> QuasarIO a
    liftUnmask unmask innerAction = do
      quasar <- askQuasar
      liftIO $ unmask $ runReaderT innerAction quasar
