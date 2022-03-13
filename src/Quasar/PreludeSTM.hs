module Quasar.PreludeSTM (
  MonadSTM,
  liftSTM,
  atomically,
  newUniqueSTM,
  module Control.Concurrent.STM,
) where

import Control.Concurrent.STM hiding (atomically)
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
