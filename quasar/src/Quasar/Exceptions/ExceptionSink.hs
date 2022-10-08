module Quasar.Exceptions.ExceptionSink (
  panicSink,
  loggingExceptionSink,
  newExceptionWitnessSink,
  newExceptionRedirector,
  newExceptionCollector,
) where

import Control.Concurrent (forkIO)
import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Monad.Catch
import Debug.Trace qualified as Trace
import GHC.IO (unsafePerformIO)
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO
import System.Exit (die)


{-# NOINLINE panicSink #-}
panicSink :: ExceptionSink
panicSink = unsafePerformIO newPanicSink

newPanicSink :: IO ExceptionSink
newPanicSink = do
  var <- newEmptyTMVarIO
  void $ forkIO $ handle (\BlockedIndefinitelyOnSTM -> pure ()) do
    ex <- atomically $ readTMVar var
    die $ "Panic: " <> displayException ex
  pure $ ExceptionSink $ void . tryPutTMVar var


loggingExceptionSink :: TIOWorker -> ExceptionSink
loggingExceptionSink worker =
  -- Logging an exception should never fail - so if it does this panics the application
  ExceptionSink \ex -> startShortIOSTM_ (logFn ex) worker panicSink
  where
    logFn :: SomeException -> ShortIO ()
    logFn ex = unsafeShortIO $ Trace.traceIO $ displayException ex

newExceptionWitnessSink :: MonadSTM' r t m => ExceptionSink -> m (ExceptionSink, STM' r2 t2 Bool)
newExceptionWitnessSink exChan = liftSTM' do
  var <- newTVar False
  let chan = ExceptionSink \ex -> lock var >> throwToExceptionSink exChan ex
  pure (chan, readTVar var)
  where
    lock :: TVar Bool -> STM' r t ()
    lock var = unlessM (readTVar var) (writeTVar var True)

newExceptionRedirector :: MonadSTM' r t m => ExceptionSink -> m (ExceptionSink, ExceptionSink -> STM' r2 t2 ())
newExceptionRedirector initialExceptionSink = do
  channelVar <- newTVar initialExceptionSink
  pure (ExceptionSink (channelFn channelVar), writeTVar channelVar)
  where
    channelFn :: TVar ExceptionSink -> SomeException -> STM' r t ()
    channelFn channelVar ex = do
      channel <- readTVar channelVar
      throwToExceptionSink channel ex

-- | Collects exceptions. After they have been collected (by using the resulting
-- transaction), further exceptions are forwarded to the backup exception sink.
-- The collection transaction may only be used once.
newExceptionCollector :: MonadSTM' r t m => ExceptionSink -> m (ExceptionSink, STM' r2 CanThrow [SomeException])
newExceptionCollector backupExceptionSink = do
  exceptionsVar <- newTVar (Just [])
  pure (ExceptionSink (channelFn exceptionsVar), gatherResult exceptionsVar)
  where
    channelFn :: TVar (Maybe [SomeException]) -> SomeException -> STM' r t ()
    channelFn exceptionsVar ex = do
      readTVar exceptionsVar >>= \case
        Just exceptions -> writeTVar exceptionsVar (Just (ex : exceptions))
        Nothing -> throwToExceptionSink backupExceptionSink ex
    gatherResult :: TVar (Maybe [SomeException]) -> STM' r CanThrow [SomeException]
    gatherResult exceptionsVar =
      swapTVar exceptionsVar Nothing >>= \case
        Just exceptions -> pure exceptions
        Nothing -> throwSTM $ userError "Exception collector result can only be generated once."
