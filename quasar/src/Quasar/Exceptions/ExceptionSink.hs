module Quasar.Exceptions.ExceptionSink (
  loggingExceptionSink,
  newExceptionWitnessSink,
  newExceptionRedirector,
  newExceptionCollector,
  ExceptionCollectorAlreadyCollected,
) where

import Control.Monad.Catch
import Quasar.Exceptions
import Quasar.Logger
import Quasar.Prelude


loggingExceptionSink :: ExceptionSink
loggingExceptionSink =
  ExceptionSink \ex -> queueLogError (displayException ex)

newExceptionWitnessSink :: MonadSTMc NoRetry '[] m => ExceptionSink -> m (ExceptionSink, STMc NoRetry '[] Bool)
newExceptionWitnessSink exChan = liftSTMc @NoRetry @'[] do
  var <- newTVar False
  let chan = ExceptionSink \ex -> lock var >> throwToExceptionSink exChan ex
  pure (chan, readTVar var)
  where
    lock :: TVar Bool -> STMc NoRetry '[] ()
    lock var = unlessM (readTVar var) (writeTVar var True)

newExceptionRedirector :: MonadSTMc NoRetry '[] m => ExceptionSink -> m (ExceptionSink, ExceptionSink -> STMc NoRetry '[] ())
newExceptionRedirector initialExceptionSink = do
  channelVar <- newTVar initialExceptionSink
  pure (ExceptionSink (channelFn channelVar), writeTVar channelVar)
  where
    channelFn :: TVar ExceptionSink -> SomeException -> STMc NoRetry '[] ()
    channelFn channelVar ex = do
      channel <- readTVar channelVar
      throwToExceptionSink channel ex

data ExceptionCollectorAlreadyCollected = ExceptionCollectorAlreadyCollected

instance Show ExceptionCollectorAlreadyCollected where
  show _ = "ExceptionCollectorAlreadyCollected: Exception collector result can only be generated once."

instance Exception ExceptionCollectorAlreadyCollected

-- | Collects exceptions. After they have been collected (by using the resulting
-- transaction), further exceptions are forwarded to the backup exception sink.
-- The collection transaction may only be used once.
newExceptionCollector :: MonadSTMc NoRetry '[] m => ExceptionSink -> m (ExceptionSink, STMc NoRetry '[ExceptionCollectorAlreadyCollected] [SomeException])
-- TODO change signature once locking ensures safety against loops
--newExceptionCollector :: MonadSTMc NoRetry '[] m => m (ExceptionSink, ExceptionSink -> STMc NoRetry '[ExceptionCollectorAlreadyCollected] [SomeException])
newExceptionCollector backupExceptionSink = do
  exceptionsVar <- newTVar (Just [])
  pure (ExceptionSink (channelFn exceptionsVar), gatherResult exceptionsVar)
  where
    channelFn :: TVar (Maybe [SomeException]) -> SomeException -> STMc NoRetry '[] ()
    channelFn exceptionsVar ex = do
      readTVar exceptionsVar >>= \case
        Just exceptions -> writeTVar exceptionsVar (Just (ex : exceptions))
        Nothing -> throwToExceptionSink backupExceptionSink ex
    gatherResult :: TVar (Maybe [SomeException]) -> STMc NoRetry '[ExceptionCollectorAlreadyCollected] [SomeException]
    gatherResult exceptionsVar =
      swapTVar exceptionsVar Nothing >>= \case
        Just exceptions -> pure exceptions
        Nothing -> throwSTM ExceptionCollectorAlreadyCollected
