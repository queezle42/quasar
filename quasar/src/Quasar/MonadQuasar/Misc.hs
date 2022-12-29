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


import Control.Monad.Catch
import Control.Monad.Reader
import Data.List.NonEmpty
import Quasar.Future
import Quasar.Async
import Quasar.Async.STMHelper
import Quasar.Exceptions.ExceptionSink
import Quasar.MonadQuasar
import Quasar.Logger
import Quasar.Prelude
import Quasar.Resources
import Quasar.Utils.Exceptions
import System.Exit


execForeignQuasarIO :: MonadIO m => Quasar -> QuasarIO () -> m ()
execForeignQuasarIO quasar fn = runQuasarIO quasar $
  bracket
    (async fn)
    dispose
    (void . await)
{-# SPECIALIZE execForeignQuasarIO :: Quasar -> QuasarIO () -> IO () #-}

execForeignQuasarSTM :: MonadSTM m => Quasar -> QuasarSTM () -> m ()
execForeignQuasarSTM quasar fn = liftSTM $ runQuasarSTM quasar $ redirectExceptionToSink_ fn
{-# SPECIALIZE execForeignQuasarSTM :: Quasar -> QuasarSTM () -> QuasarSTM () #-}


-- * High-level entry helpers

runQuasarAndExit :: Logger -> QuasarIO () -> IO a
runQuasarAndExit =
  runQuasarAndExitWith \case
   QuasarExitSuccess () -> ExitSuccess
   QuasarExitAsyncException () -> ExitFailure 1
   QuasarExitMainThreadFailed -> ExitFailure 1

data QuasarExitState a = QuasarExitSuccess a | QuasarExitAsyncException a | QuasarExitMainThreadFailed

runQuasarAndExitWith :: (QuasarExitState a -> ExitCode) -> Logger -> QuasarIO a -> IO b
runQuasarAndExitWith exitCodeFn logger fn = mask \unmask -> do
  worker <- newTIOWorker
  (exChan, exceptionWitness) <- atomically $ newExceptionWitnessSink (loggingExceptionSink worker)
  mResult <- unmask $ withQuasar logger worker exChan (redirectExceptionToSinkIO fn)
  failure <- atomicallyC $ liftSTMc exceptionWitness
  exitState <- case (mResult, failure) of
    (Just result, False) -> pure $ QuasarExitSuccess result
    (Just result, True) -> pure $ QuasarExitAsyncException result
    (Nothing, True) -> pure QuasarExitMainThreadFailed
    (Nothing, False) -> do
      traceIO "Invalid code path reached: Main thread failed but no asynchronous exception was witnessed. This is a bug, please report it to the `quasar`-project."
      pure QuasarExitMainThreadFailed
  exitWith $ exitCodeFn exitState


runQuasarCollectExceptions :: Logger -> QuasarIO a -> IO (Either SomeException a, [SomeException])
runQuasarCollectExceptions logger fn = do
  (exChan, collectExceptions) <- atomically $ newExceptionCollector panicSink
  worker <- newTIOWorker
  result <- try $ withQuasar logger worker exChan fn
  exceptions <- atomicallyC $ liftSTMc collectExceptions
  pure (result, exceptions)

runQuasarCombineExceptions :: Logger -> QuasarIO a -> IO a
runQuasarCombineExceptions logger fn = do
  (result, exceptions) <- runQuasarCollectExceptions logger fn
  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right fnResult -> maybe (pure fnResult) (throwM . CombinedException) $ nonEmpty exceptions
