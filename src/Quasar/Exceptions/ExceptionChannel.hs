module Quasar.Exception.ExceptionChannel (
  panicChannel,
  loggingExceptionChannel,
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
