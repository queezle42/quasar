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

  runQuasarIO,
  liftQuasarIO,
  quasarAtomically,

  enterQuasarIO,
  enterQuasarSTM,

  startShortIO_,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import GHC.Records (HasField(..))
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Awaitable
import Quasar.Utils.ShortIO


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

newQuasarSTM :: TIOWorker -> ExceptionChannel -> ResourceManager -> STM Quasar
newQuasarSTM worker parentExChan parentRM = do
  rm <- newUnmanagedResourceManagerSTM worker parentExChan
  attachResource parentRM rm
  pure $ Quasar worker (ExceptionChannel (disposeOnException rm)) rm
  where
    disposeOnException :: ResourceManager -> SomeException -> STM ()
    disposeOnException rm ex = do
      disposeEventuallySTM_ rm
      throwToExceptionChannel parentExChan ex

newQuasar :: MonadQuasar m => m Quasar
newQuasar = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  parentRM <- askResourceManager
  ensureSTM $ newQuasarSTM worker exChan parentRM


class (MonadCatch m, MonadFix m) => MonadQuasar m where
  askQuasar :: m Quasar
  maskIfRequired :: m a -> m a
  startShortIO :: ShortIO a -> m (Awaitable a)
  ensureSTM :: STM a -> m a
  ensureQuasarSTM :: QuasarSTM a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO

newtype QuasarSTM a = QuasarSTM (ReaderT (Quasar, TVar (Awaitable ())) STM a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadFix, Alternative)


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  askQuasar = ask
  ensureSTM t = liftIO (atomically t)
  maskIfRequired = mask_
  startShortIO fn = do
    exChan <- askExceptionChannel
    liftIO $ uninterruptibleMask_ $ try (runShortIO fn) >>= \case
      Left ex -> do
        atomically $ throwToExceptionChannel exChan ex
        pure $ throwM $ toException $ AsyncException ex
      Right result -> pure $ pure result
  ensureQuasarSTM = quasarAtomically


instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM (asks fst)
  ensureSTM fn = QuasarSTM (lift fn)
  maskIfRequired = id
  startShortIO fn = do
    (quasar, effectAwaitableVar) <- QuasarSTM ask
    let
      worker = quasarIOWorker quasar
      exChan = quasarExceptionChannel quasar

    ensureSTM do
      awaitable <- startShortIOSTM fn worker exChan
      -- Await in reverse order, so it is almost guaranteed this only retries once
      modifyTVar effectAwaitableVar (awaitSuccessOrFailure awaitable *>)
      pure awaitable
  ensureQuasarSTM = id


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  ensureSTM t = lift (ensureSTM t)
  maskIfRequired fn = do
    x <- ask
    lift $ maskIfRequired (runReaderT fn x)
  startShortIO t = lift (startShortIO t)
  ensureQuasarSTM t = lift (ensureQuasarSTM t)

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...


startShortIO_ :: MonadQuasar m => ShortIO () -> m ()
startShortIO_ fn = void $ startShortIO fn

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

runQuasarIO :: MonadIO m => Quasar -> QuasarIO a -> m a
runQuasarIO quasar fn = liftIO $ runReaderT fn quasar

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
 quasar <- askQuasar
 liftIO do
   await =<< atomically do
     effectAwaitableVar <- newTVar (pure ())
     result <- runReaderT fn (quasar, effectAwaitableVar)
     (result <$) <$> readTVar effectAwaitableVar

enterQuasarIO :: MonadIO m => Quasar -> QuasarIO () -> m ()
enterQuasarIO = undefined

enterQuasarSTM :: MonadQuasar m => Quasar -> QuasarSTM () -> m ()
enterQuasarSTM = undefined
