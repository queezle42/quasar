module Quasar.Async.STMHelper (
  TIOWorker,
  newTIOWorker,
  startShortIO,
  startShortIO_,
  fork,
  fork_,
  forkWithUnmask,
  forkWithUnmask_,
) where

import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.STM
import Control.Exception (BlockedIndefinitelyOnSTM)
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


newtype TIOWorker = TIOWorker (TQueue (IO ()))


startShortIO :: forall a. ShortIO a -> TIOWorker -> ExceptionChannel -> STM (Awaitable a)
startShortIO fn (TIOWorker jobQueue) exChan = do
  resultVar <- newAsyncVarSTM
  writeTQueue jobQueue $ job resultVar
  pure $ toAwaitable resultVar
  where
    job :: AsyncVar a -> IO ()
    job resultVar = do
      try (runShortIO fn) >>= \case
        Left ex -> do
          atomically $ throwToExceptionChannel exChan ex
          failAsyncVar_ resultVar $ toException $ AsyncException ex
        Right result -> putAsyncVar_ resultVar result

startShortIO_ :: forall a. ShortIO a -> TIOWorker -> ExceptionChannel -> STM ()
startShortIO_ x y z = void $ startShortIO x y z


newTIOWorker :: IO TIOWorker
newTIOWorker = do
  jobQueue <- newTQueueIO
  void $ forkIO $
    catch
      (forever $ join $ atomically $ readTQueue jobQueue)
      -- Relies on garbage collection to remove the thread when it is no longer needed
      (\(_ :: BlockedIndefinitelyOnSTM) -> pure ())

  pure $ TIOWorker jobQueue


fork :: IO () -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
fork fn = forkWithUnmask (\unmask -> unmask fn)

fork_ :: IO () -> TIOWorker -> ExceptionChannel -> STM ()
fork_ fn worker exChan = void $ fork fn worker exChan


forkWithUnmask :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
forkWithUnmask fn worker exChan = startShortIO forkFn worker exChan
  where
    forkFn :: ShortIO ThreadId
    forkFn = mask_ $ forkIOWithUnmaskShortIO wrappedFn
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionChannel exChan ex)

forkWithUnmask_ :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM ()
forkWithUnmask_ fn worker exChan = void $ forkWithUnmask fn worker exChan
