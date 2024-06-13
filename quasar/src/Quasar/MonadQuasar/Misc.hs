module Quasar.MonadQuasar.Misc (
  -- ** Exec code that belongs to another quasar
  execForeignQuasarIO,
  execForeignQuasarSTM,
  execForeignQuasarSTMc,

  -- ** High-level initialization
  runQuasarAndExit,
  QuasarExitState(..),
  runQuasarAndExitWith,
  runQuasarCollectExceptions,
  runQuasarCombineExceptions,
) where


import Control.Monad.Catch
import Control.Monad.Reader
import Data.List.NonEmpty
import Quasar.Async
import Quasar.Disposer
import Quasar.Exceptions
import Quasar.Exceptions.ExceptionSink
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Utils.Exceptions
import System.Exit


execForeignQuasarIO :: (MonadIO m, HasCallStack) => Quasar -> QuasarIO () -> m ()
execForeignQuasarIO quasar fn = runQuasarIO quasar $
  bracket
    (async fn)
    dispose
    (void . await)
{-# SPECIALIZE execForeignQuasarIO :: Quasar -> QuasarIO () -> IO () #-}

execForeignQuasarSTM :: MonadSTM m => Quasar -> QuasarSTM () -> m ()
execForeignQuasarSTM quasar fn = liftSTM $ runQuasarSTM quasar $ redirectExceptionToSink_ fn
{-# SPECIALIZE execForeignQuasarSTM :: Quasar -> QuasarSTM () -> QuasarSTM () #-}

execForeignQuasarSTMc :: forall canRetry m. MonadSTMc canRetry '[] m => Quasar -> QuasarSTMc canRetry '[SomeException] () -> m ()
execForeignQuasarSTMc quasar fn = do
  redirectExceptionToSinkSTMc_ quasar.exceptionSink (runQuasarSTMc' @canRetry @'[SomeException] quasar fn)


-- * High-level entry helpers

runQuasarAndExit :: QuasarIO () -> IO a
runQuasarAndExit =
  runQuasarAndExitWith \case
   QuasarExitSuccess () -> ExitSuccess
   QuasarExitAsyncException () -> ExitFailure 1
   QuasarExitMainThreadFailed -> ExitFailure 1

data QuasarExitState a = QuasarExitSuccess a | QuasarExitAsyncException a | QuasarExitMainThreadFailed

runQuasarAndExitWith :: (QuasarExitState a -> ExitCode) -> QuasarIO a -> IO b
runQuasarAndExitWith exitCodeFn fn = mask \unmask -> do
  (exChan, exceptionWitness) <- atomically $ newExceptionWitnessSink loggingExceptionSink
  mResult <- unmask $ withQuasar exChan (redirectExceptionToSinkIO fn)
  failure <- atomicallyC $ liftSTMc exceptionWitness
  exitState <- case (mResult, failure) of
    (Just result, False) -> pure $ QuasarExitSuccess result
    (Just result, True) -> pure $ QuasarExitAsyncException result
    (Nothing, True) -> pure QuasarExitMainThreadFailed
    (Nothing, False) -> do
      traceIO "Invalid code path reached: Main thread failed but no asynchronous exception was witnessed. This is a bug, please report it to the `quasar`-project."
      pure QuasarExitMainThreadFailed
  exitWith $ exitCodeFn exitState


runQuasarCollectExceptions :: QuasarIO a -> IO (Either SomeException a, [SomeException])
runQuasarCollectExceptions fn = do
  (exChan, collectExceptions) <- atomically $ newExceptionCollector loggingExceptionSink
  result <- try $ withQuasar exChan fn
  exceptions <- atomicallyC collectExceptions
  pure (result, exceptions)

runQuasarCombineExceptions :: QuasarIO a -> IO a
runQuasarCombineExceptions fn = do
  (result, exceptions) <- runQuasarCollectExceptions fn
  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right fnResult -> maybe (pure fnResult) (throwM . CombinedException) $ nonEmpty exceptions
