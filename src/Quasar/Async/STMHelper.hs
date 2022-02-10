module Quasar.Async.STMHelper (
  TIOWorker,
  newTIOWorker,
  startTrivialIO,
  startTrivialIO_,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (BlockedIndefinitelyOnSTM)
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude


newtype TIOWorker = TIOWorker (TQueue (IO ()))


startTrivialIO :: forall a. TIOWorker -> ExceptionChannel -> IO a -> STM (Awaitable a)
startTrivialIO (TIOWorker jobQueue) exChan fn = do
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

startTrivialIO_ :: forall a. TIOWorker -> ExceptionChannel -> IO a -> STM ()
startTrivialIO_ x y z = void $ startTrivialIO x y z


newTIOWorker :: IO TIOWorker
newTIOWorker = do
  jobQueue <- newTQueueIO
  void $ forkIO $
    catch
      (forever $ join $ atomically $ readTQueue jobQueue)
      -- Relies on garbage collection to remove the thread when it is no longer needed
      (\(_ :: BlockedIndefinitelyOnSTM) -> pure ())
    
  pure $ TIOWorker jobQueue
