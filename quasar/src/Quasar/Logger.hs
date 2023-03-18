{-# LANGUAGE UndecidableInstances #-}

module Quasar.Logger (
  LogMessage,
  LogLevel(..),
  flushLogger,

  logMessage,
  logCritical,
  logError,
  logWarning,
  logInfo,
  logDebug,
  logString,

  queueLogMessage,
  queueLogCritical,
  queueLogError,
  queueLogWarning,
  queueLogInfo,
  queueLogDebug,
  queueLogString,

  Logger(logLevel, logBufferSize),
  globalLogger,
) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Monad.Catch
import Debug.Trace qualified
import Quasar.Prelude
import System.IO.Unsafe (unsafePerformIO)


data Logger = Logger {
  logQueue :: TQueue LogMessage,
  logLevel :: TVar LogLevel,
  logBufferSize :: TVar Word64,
  queuedCounter :: TVar Word64,
  loggedCounter :: TVar Word64
}

newLogger :: ([LogMessage] -> IO ()) -> IO Logger
newLogger logFn = do
  logQueue <- newTQueueIO
  logLevel <- newTVarIO LogLevelInfo
  logBufferSize <- newTVarIO 4
  queuedCounter <- newTVarIO 0
  loggedCounter <- newTVarIO 0

  void $ forkIOWithUnmask \unmask -> unmask do
    handle (\BlockedIndefinitelyOnSTM -> pure ()) do
      forever do
        items <- atomically do
          items <- flushTQueue logQueue
          check (not (null items))
          pure items
        logFn items
        atomically do
          modifyTVar loggedCounter (+ fromIntegral (length items))

  pure Logger {
    logQueue,
    logLevel,
    logBufferSize,
    queuedCounter,
    loggedCounter
  }

globalLogger :: Logger
globalLogger =
  unsafePerformIO $ newLogger \items -> do
    forM_ items \(LogMessage _ msg) -> do
      Debug.Trace.traceIO msg
{-# NOINLINE globalLogger #-}

flushLogger :: IO ()
flushLogger = do
  initialQueued <- readTVarIO (queuedCounter globalLogger)
  atomically do
    currentLogged <- readTVar (loggedCounter globalLogger)
    check (initialQueued <= currentLogged)

logMessage :: MonadIO m => LogMessage -> m ()
logMessage message@(LogMessage level _) = liftIO do
  threshold <- readTVarIO (logLevel globalLogger)
  when (level <= threshold) do
    atomically do
      queued <- readTVar (queuedCounter globalLogger)
      logged <- readTVar (loggedCounter globalLogger)
      bufferSize <- readTVar (logBufferSize globalLogger)
      check (queued - logged < bufferSize)
      writeTQueue (logQueue globalLogger) message
      writeTVar (queuedCounter globalLogger) (queued + 1)


queueLogMessage :: MonadSTMc NoRetry '[] m => LogMessage -> m ()
queueLogMessage message@(LogMessage level _) = liftSTMc @NoRetry @'[] do
  threshold <- readTVar (logLevel globalLogger)
  when (level <= threshold) do
    writeTQueue (logQueue globalLogger) message
    queued <- readTVar (queuedCounter globalLogger)
    writeTVar (queuedCounter globalLogger) (queued + 1)



data LogLevel
  = LogLevelCritical
  | LogLevelError
  | LogLevelWarning
  | LogLevelInfo
  | LogLevelDebug
  deriving stock (Bounded, Eq, Enum, Ord, Show)

data LogMessage = LogMessage LogLevel String

logCritical :: MonadIO m => String -> m ()
logCritical = logString LogLevelCritical

logError :: MonadIO m => String -> m ()
logError = logString LogLevelError

logWarning :: MonadIO m => String -> m ()
logWarning = logString LogLevelWarning

logInfo :: MonadIO m => String -> m ()
logInfo = logString LogLevelInfo

logDebug :: MonadIO m => String -> m ()
logDebug = logString LogLevelDebug

logString :: MonadIO m => LogLevel -> String -> m ()
logString level msg = logMessage $ LogMessage level msg


queueLogCritical :: MonadSTMc NoRetry '[] m => String -> m ()
queueLogCritical = queueLogString LogLevelCritical

queueLogError :: MonadSTMc NoRetry '[] m => String -> m ()
queueLogError = queueLogString LogLevelError

queueLogWarning :: MonadSTMc NoRetry '[] m => String -> m ()
queueLogWarning = queueLogString LogLevelWarning

queueLogInfo :: MonadSTMc NoRetry '[] m => String -> m ()
queueLogInfo = queueLogString LogLevelInfo

queueLogDebug :: MonadSTMc NoRetry '[] m => String -> m ()
queueLogDebug = queueLogString LogLevelDebug

queueLogString :: MonadSTMc NoRetry '[] m => LogLevel -> String -> m ()
queueLogString level msg = queueLogMessage $ LogMessage level msg
