module Quasar.Async.STMHelper (
  -- * Helper to fork from STM
  TIOWorker,
  newTIOWorker,
  enqueueForkIO,
  startShortIOSTM,
  startShortIOSTM_,
) where

import Control.Concurrent (forkIO)
import Control.Exception (BlockedIndefinitelyOnSTM, interruptible)
import Control.Monad.Catch
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


newtype TIOWorker = TIOWorker (TQueue (IO ()))

startShortIOSTM :: forall a m. MonadSTMc '[] m => ShortIO a -> TIOWorker -> ExceptionSink -> m (FutureE a)
startShortIOSTM fn (TIOWorker jobQueue) exChan = liftSTMc @'[] do
  resultVar <- newPromiseSTM
  writeTQueue jobQueue $ job resultVar
  pure $ toFutureE resultVar
  where
    job :: Promise (Either SomeException a) -> IO ()
    job resultVar = do
      try (runShortIO fn) >>= \case
        Left ex -> do
          atomically $ throwToExceptionSink exChan ex
          fulfillPromise resultVar (Left $ toException $ AsyncException ex)
        Right result -> fulfillPromise resultVar (Right result)

startShortIOSTM_ :: MonadSTMc '[] m => ShortIO () -> TIOWorker -> ExceptionSink -> m ()
startShortIOSTM_ x y z = void $ startShortIOSTM x y z


newTIOWorker :: IO TIOWorker
newTIOWorker = do
  jobQueue <- newTQueueIO
  void $ forkIO $
    -- interruptible sets a defined masking state for new threads
    interruptible $ catch
      (forever $ join $ atomically $ readTQueue jobQueue)
      -- Relies on garbage collection to remove the thread when it is no longer needed
      (\(_ :: BlockedIndefinitelyOnSTM) -> pure ())

  pure $ TIOWorker jobQueue


enqueueForkIO :: MonadSTMc '[] m => TIOWorker -> IO () -> m ()
enqueueForkIO (TIOWorker jobQueue) fn = writeTQueue jobQueue (void (forkIO fn))
