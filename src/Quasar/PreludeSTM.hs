module Quasar.PreludeSTM (
  MonadSTM,
  liftSTM,
  atomically,
  newUniqueSTM,
  module Control.Concurrent.STM,
  newTVar,
  newTVarIO,
  readTVar,
  readTVarIO,
  writeTVar,
  modifyTVar,
  modifyTVar',
  stateTVar,
  swapTVar,
) where

import Control.Concurrent.STM hiding (
  atomically,
  newTVar,
  newTVarIO,
  readTVar,
  readTVarIO,
  writeTVar,
  modifyTVar,
  modifyTVar',
  stateTVar,
  swapTVar,
  )
import Control.Concurrent.STM qualified as STM
import Control.Monad.Base
import Control.Monad.IO.Class
import Data.Unique (Unique, newUnique)
import GHC.Conc (unsafeIOToSTM)
import Prelude

type MonadSTM = MonadBase STM

liftSTM :: MonadSTM m => STM a -> m a
liftSTM = liftBase

atomically :: MonadIO m => STM a -> m a
atomically t = liftIO (STM.atomically t)

newUniqueSTM :: MonadSTM m => m Unique
newUniqueSTM = liftSTM (unsafeIOToSTM newUnique)

newTVar :: MonadSTM m => a -> m (TVar a)
newTVar = liftSTM . STM.newTVar

newTVarIO :: MonadIO m => a -> m (TVar a)
newTVarIO = liftIO . STM.newTVarIO

readTVar :: MonadSTM m => TVar a -> m a
readTVar = liftSTM . STM.readTVar

readTVarIO :: MonadIO m => TVar a -> m a
readTVarIO = liftIO . STM.readTVarIO

writeTVar :: MonadSTM m => TVar a -> a -> m ()
writeTVar var = liftSTM . STM.writeTVar var

modifyTVar :: MonadSTM m => TVar a -> (a -> a) -> m ()
modifyTVar var = liftSTM . STM.modifyTVar var

modifyTVar' :: MonadSTM m => TVar a -> (a -> a) -> m ()
modifyTVar' var = liftSTM . STM.modifyTVar' var

stateTVar :: MonadSTM m => TVar s -> (s -> (a, s)) -> m a
stateTVar var = liftSTM . STM.stateTVar var

swapTVar :: MonadSTM m => TVar a -> a -> m a
swapTVar var = liftSTM . STM.swapTVar var
