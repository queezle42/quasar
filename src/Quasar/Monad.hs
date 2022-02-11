module Quasar.Monad (
  Quasar,
  newQuasar,

  MonadQuasar(..),
  askIOWorker,
  askExceptionChannel,
  askResourceManager,

  QuasarT,
  QuasarIO,
  QuasarSTM,

  liftQuasarIO,
  runQuasarSTM,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import GHC.Records (HasField(..))
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Disposer


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the channel
data Quasar = Quasar TIOWorker ExceptionChannel ResourceManager

instance Resource Quasar where
  getDisposer (Quasar _ _ rm) = getDisposer rm

instance HasField "ioWorker" Quasar TIOWorker where
  getField = quasarIOWorker

instance HasField "exceptionChannel" Quasar ExceptionChannel where
  getField = quasarExceptionChannel

instance HasField "resourceManager" Quasar ResourceManager where
  getField = quasarResourceManager

quasarIOWorker :: Quasar -> TIOWorker
quasarIOWorker (Quasar worker _ _) = worker

quasarExceptionChannel :: Quasar -> ExceptionChannel
quasarExceptionChannel (Quasar _ exChan _) = exChan

quasarResourceManager :: Quasar -> ResourceManager
quasarResourceManager (Quasar _ _ rm) = rm

newQuasar :: TIOWorker -> ExceptionChannel -> ResourceManager -> STM Quasar
newQuasar worker parentExChan parentRM = do
  rm <- newResourceManagerSTM worker parentExChan
  attachResource parentRM rm
  pure $ Quasar worker (ExceptionChannel (disposeOnException rm)) rm
  where
    disposeOnException :: ResourceManager -> SomeException -> STM ()
    disposeOnException rm ex = do
      disposeEventuallySTM_ rm
      throwToExceptionChannel parentExChan ex


class (MonadCatch m, MonadFix m) => MonadQuasar m where
  askQuasar :: m Quasar
  runSTM :: STM a -> m a
  maskIfRequired :: m a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO
type QuasarSTM = QuasarT STM


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  askQuasar = ask
  runSTM t = liftIO (atomically t)
  maskIfRequired = mask_

-- Overlaps the QuasartT/MonadIO-instance, because `MonadIO` _could_ be specified for `STM` (but that would be _very_ incorrect, so this is safe).
instance {-# OVERLAPS #-} MonadQuasar (QuasarT STM) where
  askQuasar = ask
  runSTM = lift
  maskIfRequired = id


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  runSTM t = lift (runSTM t)
  maskIfRequired fn = do
    x <- ask
    lift $ maskIfRequired (runReaderT fn x)

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...


askIOWorker :: MonadQuasar m => m TIOWorker
askIOWorker = quasarIOWorker <$> askQuasar

askExceptionChannel :: MonadQuasar m => m ExceptionChannel
askExceptionChannel = quasarExceptionChannel <$> askQuasar

askResourceManager :: MonadQuasar m => m ResourceManager
askResourceManager = quasarResourceManager <$> askQuasar


liftQuasarIO :: (MonadIO m, MonadQuasar m) => QuasarIO a -> m a
liftQuasarIO fn = do
  quasar <- askQuasar
  liftIO $ runReaderT fn quasar

runQuasarSTM :: MonadQuasar m => QuasarSTM a -> m a
runQuasarSTM fn = do
  quasar <- askQuasar
  runSTM $ runReaderT fn quasar