module Quasar.Async.STMHelper (
  -- * Helper to fork from STM
  TIOWorker,
  newTIOWorker,
  startShortIO,
  startShortIO_,
) where

import Control.Concurrent (forkIO)
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

startShortIO_ :: ShortIO () -> TIOWorker -> ExceptionChannel -> STM ()
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
