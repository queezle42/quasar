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
{-# SPECIALIZE liftSTM :: STM a -> STM a #-}

atomically :: MonadIO m => STM a -> m a
atomically t = liftIO (STM.atomically t)
{-# SPECIALIZE atomically :: STM a -> IO a #-}

newUniqueSTM :: MonadSTM m => m Unique
newUniqueSTM = liftSTM (unsafeIOToSTM newUnique)
{-# SPECIALIZE newUniqueSTM :: STM Unique #-}

newTVar :: MonadSTM m => a -> m (TVar a)
newTVar = liftSTM . STM.newTVar
{-# SPECIALIZE newTVar :: a -> STM (TVar a) #-}

newTVarIO :: MonadIO m => a -> m (TVar a)
newTVarIO = liftIO . STM.newTVarIO
{-# SPECIALIZE newTVarIO :: a -> IO (TVar a) #-}

readTVar :: MonadSTM m => TVar a -> m a
readTVar = liftSTM . STM.readTVar
{-# SPECIALIZE readTVar :: TVar a -> STM a #-}

readTVarIO :: MonadIO m => TVar a -> m a
readTVarIO = liftIO . STM.readTVarIO
{-# SPECIALIZE readTVarIO :: TVar a -> IO a #-}

writeTVar :: MonadSTM m => TVar a -> a -> m ()
writeTVar var = liftSTM . STM.writeTVar var
{-# SPECIALIZE writeTVar :: TVar a -> a -> STM () #-}

modifyTVar :: MonadSTM m => TVar a -> (a -> a) -> m ()
modifyTVar var = liftSTM . STM.modifyTVar var
{-# SPECIALIZE modifyTVar :: TVar a -> (a -> a) -> STM () #-}

modifyTVar' :: MonadSTM m => TVar a -> (a -> a) -> m ()
modifyTVar' var = liftSTM . STM.modifyTVar' var
{-# SPECIALIZE modifyTVar' :: TVar a -> (a -> a) -> STM () #-}

stateTVar :: MonadSTM m => TVar s -> (s -> (a, s)) -> m a
stateTVar var = liftSTM . STM.stateTVar var
{-# SPECIALIZE stateTVar :: TVar s -> (s -> (a, s)) -> STM a #-}

swapTVar :: MonadSTM m => TVar a -> a -> m a
swapTVar var = liftSTM . STM.swapTVar var
{-# SPECIALIZE swapTVar :: TVar a -> a -> STM a #-}
