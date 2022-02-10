module Quasar.Monad (
  Quasar,
  newQuasar,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,

) where

import Control.Concurrent.STM
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources
import Control.Monad.Reader


data Quasar = Quasar TIOWorker ExceptionChannel ResourceManager

newQuasar :: TIOWorker -> ExceptionChannel -> ResourceManager -> STM Quasar
newQuasar = undefined


class Monad m => MonadQuasar m where
  askQuasar :: m Quasar
  runSTM :: STM a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO
type QuasarSTM = QuasarT STM


instance MonadIO m => MonadQuasar (QuasarT m) where
  askQuasar = ask
  runSTM t = liftIO (atomically t)

-- Overlaps the QuasartT/MonadIO-instance, because `MonadIO` _could_ be specified for `STM` (but that would be _very_ incorrect, so this is safe).
instance {-# OVERLAPS #-} MonadQuasar (QuasarT STM) where
  askQuasar = ask
  runSTM = lift


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  runSTM t = lift (runSTM t)

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...
