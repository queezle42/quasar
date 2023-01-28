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

startShortIOSTM :: forall a m. MonadSTMc NoRetry '[] m => ShortIO a -> TIOWorker -> ExceptionSink -> m (FutureEx '[AsyncException] a)
startShortIOSTM fn (TIOWorker jobQueue) exChan = liftSTMc @NoRetry @'[] do
  resultVar <- newPromise
  writeTQueue jobQueue $ job resultVar
  pure $ toFutureEx resultVar
  where
    job :: PromiseEx '[AsyncException] a -> IO ()
    job resultVar = do
      try (runShortIO fn) >>= \case
        Left ex -> do
          atomically $ throwToExceptionSink exChan ex
          fulfillPromiseIO resultVar (Left $ toEx $ AsyncException ex)
        Right result -> fulfillPromiseIO resultVar (Right result)

startShortIOSTM_ :: MonadSTMc NoRetry '[] m => ShortIO () -> TIOWorker -> ExceptionSink -> m ()
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


enqueueForkIO :: MonadSTMc NoRetry '[] m => TIOWorker -> IO () -> m ()
enqueueForkIO (TIOWorker jobQueue) fn = writeTQueue jobQueue (void (forkIO fn))
