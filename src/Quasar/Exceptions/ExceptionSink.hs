module Quasar.Exceptions.ExceptionSink (
  panicChannel,
  loggingExceptionChannel,
  newExceptionChannelWitness,
  newExceptionRedirector,
  newExceptionCollector
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Monad.Catch
import Debug.Trace qualified as Trace
import GHC.IO (unsafePerformIO)
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO
import System.Exit (die)


{-# NOINLINE panicChannel #-}
panicChannel :: ExceptionChannel
panicChannel = unsafePerformIO newPanicChannel

newPanicChannel :: IO ExceptionChannel
newPanicChannel = do
  var <- newEmptyTMVarIO
  void $ forkIO $ handle (\BlockedIndefinitelyOnSTM -> pure ()) do
    ex <- atomically $ readTMVar var
    die $ "Panic: " <> displayException ex
  pure $ ExceptionChannel $ void . tryPutTMVar var


loggingExceptionChannel :: TIOWorker -> ExceptionChannel
loggingExceptionChannel worker =
  -- Logging an exception should never fail - so if it does this panics the application
  ExceptionChannel \ex -> startShortIOSTM_ (logFn ex) worker panicChannel
  where
    logFn :: SomeException -> ShortIO ()
    logFn ex = unsafeShortIO $ Trace.traceIO $ displayException ex

newExceptionChannelWitness :: ExceptionChannel -> STM (ExceptionChannel, STM Bool)
newExceptionChannelWitness exChan = do
  var <- newTVar False
  let chan = ExceptionChannel \ex -> lock var >> throwToExceptionChannel exChan ex
  pure (chan, readTVar var)
  where
    lock :: TVar Bool -> STM ()
    lock var = unlessM (readTVar var) (writeTVar var True)

newExceptionRedirector :: ExceptionChannel -> STM (ExceptionChannel, ExceptionChannel -> STM ())
newExceptionRedirector initialExceptionChannel = do
  channelVar <- newTVar initialExceptionChannel
  pure (ExceptionChannel (channelFn channelVar), writeTVar channelVar)
  where
    channelFn :: TVar ExceptionChannel -> SomeException -> STM ()
    channelFn channelVar ex = do
      channel <- readTVar channelVar
      throwToExceptionChannel channel ex

-- | Collects exceptions. After they have been collected (by using the resulting
-- transaction), further exceptions are forwarded to the backup exception sink.
-- The collection transaction may only be used once.
newExceptionCollector :: ExceptionChannel -> STM (ExceptionChannel, STM [SomeException])
newExceptionCollector backupExceptionChannel = do
  exceptionsVar <- newTVar (Just [])
  pure (ExceptionChannel (channelFn exceptionsVar), gatherResult exceptionsVar)
  where
    channelFn :: TVar (Maybe [SomeException]) -> SomeException -> STM ()
    channelFn exceptionsVar ex = do
      readTVar exceptionsVar >>= \case
        Just exceptions -> writeTVar exceptionsVar (Just (ex : exceptions))
        Nothing -> throwToExceptionChannel backupExceptionChannel ex
    gatherResult :: TVar (Maybe [SomeException]) -> STM [SomeException]
    gatherResult exceptionsVar =
      swapTVar exceptionsVar Nothing >>= \case
        Just exceptions -> pure exceptions
        Nothing -> throwSTM $ userError "Exception collector result can only be generated once."
