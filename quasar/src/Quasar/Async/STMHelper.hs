module Quasar.Async.STMHelper (
  -- * Helper to fork from STM
  TIOWorker,
  newTIOWorker,
  startShortIOSTM,
  startShortIOSTM_,
) where

import Control.Concurrent (forkIO)
import Control.Exception (BlockedIndefinitelyOnSTM)
import Control.Monad.Catch
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


newtype TIOWorker = TIOWorker (TQueue (IO ()))


startShortIOSTM :: forall a m r t. MonadSTM' r t m => ShortIO a -> TIOWorker -> ExceptionSink -> m (Future a)
startShortIOSTM fn (TIOWorker jobQueue) exChan = liftSTM' do
  resultVar <- newPromiseSTM
  writeTQueue jobQueue $ job resultVar
  pure $ toFuture resultVar
  where
    job :: Promise a -> IO ()
    job resultVar = do
      try (runShortIO fn) >>= \case
        Left ex -> do
          atomically $ throwToExceptionSink exChan ex
          breakPromise resultVar $ toException $ AsyncException ex
        Right result -> fulfillPromise resultVar result

startShortIOSTM_ :: MonadSTM' r t m => ShortIO () -> TIOWorker -> ExceptionSink -> m ()
startShortIOSTM_ x y z = void $ startShortIOSTM x y z


newTIOWorker :: IO TIOWorker
newTIOWorker = do
  jobQueue <- newTQueueIO
  void $ forkIO $
    catch
      (forever $ join $ atomically $ readTQueue jobQueue)
      -- Relies on garbage collection to remove the thread when it is no longer needed
      (\(_ :: BlockedIndefinitelyOnSTM) -> pure ())

  pure $ TIOWorker jobQueue
