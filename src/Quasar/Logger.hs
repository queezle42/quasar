module Quasar.Logger (
  MonadLog(..),
  LogLevel(..),
  logCritical,
  logError,
  logWarning,
  logInfo,
  logDebug,
  logString,

  LogWriterT,
  LogWriter,
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

type LogWriterT = WriterT [LogMessage]
type LogWriter = LogWriterT Identity

class Monad m => MonadLog m where
  logMessage :: LogMessage -> m ()

instance Monad m => MonadLog (LogWriterT m) where
  logMessage msg = tell [msg]

instance {-# OVERLAPPABLE #-} MonadLog m => MonadLog (ReaderT r m) where
  logMessage = lift . logMessage

-- TODO MonadLog instances for StateT, WriterT, RWST, MaybeT, ...

logCritical :: MonadLog m => String -> m ()
logCritical = logString LogLevelCritical

logError :: MonadLog m => String -> m ()
logError = logString LogLevelError

logWarning :: MonadLog m => String -> m ()
logWarning = logString LogLevelWarning

logInfo :: MonadLog m => String -> m ()
logInfo = logString LogLevelInfo

logDebug :: MonadLog m => String -> m ()
logDebug = logString LogLevelDebug

logString :: MonadLog m => LogLevel -> String -> m ()
logString level msg = logMessage $ LogMessage level msg


type Logger = LogMessage -> IO ()

stderrLogger :: LogLevel -> Logger
stderrLogger threshold (LogMessage level msg) = do
  when (level <= threshold) $ Debug.Trace.traceIO msg
