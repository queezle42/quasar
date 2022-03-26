module Quasar.Logger (
  MonadLogger(..),
  LogLevel(..),
  logCritical,
  logError,
  logWarning,
  logInfo,
  logDebug,
  logString,

  LoggerT,
  LogMessage,
  Logger,
  stderrLogger,
) where

import Quasar.Prelude
import Debug.Trace qualified
import Control.Monad.Reader
import Control.Monad.Writer

data LogLevel
  = LogLevelCritical
  | LogLevelError
  | LogLevelWarning
  | LogLevelInfo
  | LogLevelDebug
  deriving stock (Bounded, Eq, Enum, Ord, Show)

data LogMessage = LogMessage LogLevel String

type LoggerT = WriterT [LogMessage]

class Monad m => MonadLogger m where
  logMessage :: LogMessage -> m ()

instance Monad m => MonadLogger (LoggerT m) where
  logMessage msg = tell [msg]

instance {-# OVERLAPPABLE #-} MonadLogger m => MonadLogger (ReaderT r m) where
  logMessage = lift . logMessage

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...

logCritical :: MonadLogger m => String -> m ()
logCritical = logString LogLevelCritical

logError :: MonadLogger m => String -> m ()
logError = logString LogLevelError

logWarning :: MonadLogger m => String -> m ()
logWarning = logString LogLevelWarning

logInfo :: MonadLogger m => String -> m ()
logInfo = logString LogLevelInfo

logDebug :: MonadLogger m => String -> m ()
logDebug = logString LogLevelDebug

logString :: MonadLogger m => LogLevel -> String -> m ()
logString level msg = logMessage $ LogMessage level msg


type Logger = LogMessage -> IO ()

stderrLogger :: LogLevel -> Logger
stderrLogger threshold (LogMessage level msg) = do
  when (level <= threshold) $ Debug.Trace.traceIO msg
