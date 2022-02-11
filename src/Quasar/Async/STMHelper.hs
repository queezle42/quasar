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

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Exception (BlockedIndefinitelyOnSTM)
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude


newtype TIOWorker = TIOWorker (TQueue (IO ()))


startShortIO :: forall a. TIOWorker -> ExceptionChannel -> IO a -> STM (Awaitable a)
startShortIO (TIOWorker jobQueue) exChan fn = do
  resultVar <- newAsyncVarSTM
  writeTQueue jobQueue $ job resultVar
  pure $ toAwaitable resultVar
  where
    job :: AsyncVar a -> IO ()
    job resultVar = do
      try fn >>= \case
        Left ex -> do
          atomically $ throwToExceptionChannel exChan ex
          failAsyncVar_ resultVar $ toException $ AsyncException ex
        Right result -> putAsyncVar_ resultVar result

startShortIO_ :: forall a. TIOWorker -> ExceptionChannel -> IO a -> STM ()
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


fork :: TIOWorker -> ExceptionChannel -> IO () -> STM (Awaitable ThreadId)
fork worker exChan fn = forkWithUnmask worker exChan (\unmask -> unmask fn)

fork_ :: TIOWorker -> ExceptionChannel -> IO () -> STM ()
fork_ worker exChan fn = void $ fork worker exChan fn


forkWithUnmask :: TIOWorker -> ExceptionChannel -> ((forall a. IO a -> IO a) -> IO ()) -> STM (Awaitable ThreadId)
forkWithUnmask worker exChan fn = startShortIO worker exChan launcher
  where
    launcher :: IO ThreadId
    launcher = mask_ $ forkIOWithUnmask wrappedFn
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionChannel exChan ex)

forkWithUnmask_ :: TIOWorker -> ExceptionChannel -> ((forall a. IO a -> IO a) -> IO ()) -> STM ()
forkWithUnmask_ worker exChan fn = void $ forkWithUnmask worker exChan fn
