module Quasar.MonadQuasar.Misc (
  -- ** Exec code that belongs to another quasar
  execForeignQuasarIO,
  execForeignQuasarSTM,

  -- ** High-level initialization
  runQuasarAndExit,
  runQuasarAndExitWith,
  runQuasarCollectExceptions,
  runQuasarCombineExceptions,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.List.NonEmpty
import Quasar.Future
import Quasar.Async
import Quasar.Async.STMHelper
import Quasar.Exceptions.ExceptionSink
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Quasar.Utils.Exceptions
import System.Exit


execForeignQuasarIO :: MonadIO m => Quasar -> QuasarIO () -> m ()
execForeignQuasarIO quasar fn = runQuasarIO quasar $
  bracket
    (async fn)
    dispose
    awaitSuccessOrFailure

execForeignQuasarSTM :: MonadQuasar m => Quasar -> QuasarSTM () -> m ()
execForeignQuasarSTM quasar fn = ensureQuasarSTM $ localQuasar quasar $ redirectExceptionToSink_ fn



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
  worker <- newTIOWorker
  (exChan, exceptionWitness) <- atomically $ newExceptionWitnessSink (loggingExceptionSink worker)
  mResult <- unmask $ withQuasarGeneric worker exChan (redirectExceptionToSink fn)
  failure <- atomically exceptionWitness
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
  (exChan, collectExceptions) <- atomically $ newExceptionCollector panicSink
  worker <- newTIOWorker
  result <- try $ withQuasarGeneric worker exChan fn
  exceptions <- atomically collectExceptions
  pure (result, exceptions)

runQuasarCombineExceptions :: QuasarIO a -> IO a
runQuasarCombineExceptions fn = do
  (result, exceptions) <- runQuasarCollectExceptions fn
  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right fnResult -> maybe (pure fnResult) (throwM . CombinedException) $ nonEmpty exceptions
