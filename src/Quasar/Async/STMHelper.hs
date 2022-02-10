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


newtype TIOWorker = TIOWorker (TMVar (IO ()))


startTrivialIO :: forall a. TIOWorker -> ExceptionChannel -> IO a -> STM (Awaitable a)
startTrivialIO (TIOWorker jobVar) exChan fn = do
  resultVar <- newAsyncVarSTM
  putTMVar jobVar $ job resultVar
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
  jobVar <- newEmptyTMVarIO
  void $ forkIO $
    handle
      -- Relies on garbage collection to remove the thread when it is no longer needed
      (\(_ :: BlockedIndefinitelyOnSTM) -> pure ())
      (forever $ join $ atomically $ takeTMVar jobVar)
    
  pure $ TIOWorker jobVar
