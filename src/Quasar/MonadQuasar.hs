module Quasar.MonadQuasar (
  -- * Quasar
  Quasar,
  newResourceScope,
  newResourceScopeSTM,
  withResourceScope,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,

  withQuasarGeneric,
  runQuasarIO,
  runQuasarSTM,
  liftQuasarIO,
  quasarAtomically,

  -- ** Utils
  redirectExceptionToSink,
  redirectExceptionToSink_,

  -- ** Get quasar components
  quasarIOWorker,
  quasarExceptionSink,
  quasarResourceManager,
  askIOWorker,
  askExceptionSink,
  askResourceManager,
) where

import Control.Monad.Catch
import Control.Monad.Reader
import GHC.Records (HasField(..))
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Logger
import Quasar.Prelude
import Quasar.Resources.Disposer


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the channel
data Quasar = Quasar Logger TIOWorker ExceptionSink ResourceManager

instance Resource Quasar where
  getDisposer (Quasar _ _ _ rm) = getDisposer rm

instance HasField "logger" Quasar Logger where
  getField = quasarLogger

instance HasField "ioWorker" Quasar TIOWorker where
  getField = quasarIOWorker

instance HasField "exceptionSink" Quasar ExceptionSink where
  getField = quasarExceptionSink

instance HasField "resourceManager" Quasar ResourceManager where
  getField = quasarResourceManager

quasarLogger :: Quasar -> Logger
quasarLogger (Quasar logger _ _ _) = logger

quasarIOWorker :: Quasar -> TIOWorker
quasarIOWorker (Quasar _ worker _ _) = worker

quasarExceptionSink :: Quasar -> ExceptionSink
quasarExceptionSink (Quasar _ _ exChan _) = exChan

quasarResourceManager :: Quasar -> ResourceManager
quasarResourceManager (Quasar _ _ _ rm) = rm

newResourceScopeSTM :: Quasar -> STM Quasar
newResourceScopeSTM parent = do
  rm <- newUnmanagedResourceManagerSTM worker parentExceptionSink
  attachResource (quasarResourceManager parent) rm
  pure $ Quasar logger worker (ExceptionSink (disposeOnException rm)) rm
  where
    logger = quasarLogger parent
    worker = quasarIOWorker parent
    parentExceptionSink = quasarExceptionSink parent
    disposeOnException :: ResourceManager -> SomeException -> STM ()
    disposeOnException rm ex = do
      disposeEventuallySTM_ rm
      throwToExceptionSink parentExceptionSink ex

newResourceScope :: MonadQuasar m => m Quasar
newResourceScope = ensureSTM . newResourceScopeSTM =<< askQuasar
{-# SPECIALIZE newResourceScope :: QuasarIO Quasar #-}
{-# SPECIALIZE newResourceScope :: QuasarSTM Quasar #-}


withResourceScope :: (MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
withResourceScope fn = bracket newResourceScope dispose (`localQuasar` fn)
{-# SPECIALIZE withResourceScope :: QuasarIO a -> QuasarIO a #-}


class (MonadCatch m, MonadFix m) => MonadQuasar m where
  askQuasar :: m Quasar
  maskIfRequired :: m a -> m a
  ensureSTM :: STM a -> m a
  ensureQuasarSTM :: QuasarSTM a -> m a
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO

newtype QuasarSTM a = QuasarSTM (QuasarT STM a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadFix, Alternative, MonadSTM)


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  askQuasar = ask
  ensureSTM t = liftIO (atomically t)
  maskIfRequired = mask_
  ensureQuasarSTM = quasarAtomically
  localQuasar quasar = local (const quasar)
  {-# SPECIALIZE instance MonadQuasar QuasarIO #-}

instance (MonadIO m, MonadMask m, MonadFix m) => MonadLog (QuasarT m) where
  logMessage msg = do
    logger <- askLogger
    liftIO $ logger msg
  {-# SPECIALIZE instance MonadLog QuasarIO #-}


instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM ask
  ensureSTM fn = QuasarSTM (lift fn)
  maskIfRequired = id
  ensureQuasarSTM = id
  localQuasar quasar (QuasarSTM fn) = QuasarSTM (local (const quasar) fn)


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  ensureSTM t = lift (ensureSTM t)
  maskIfRequired fn = do
    x <- ask
    lift $ maskIfRequired (runReaderT fn x)
  ensureQuasarSTM t = lift (ensureQuasarSTM t)
  localQuasar quasar fn = do
    x <- ask
    lift (localQuasar quasar (runReaderT fn x))

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...


askLogger :: MonadQuasar m => m Logger
askLogger = quasarLogger <$> askQuasar

askIOWorker :: MonadQuasar m => m TIOWorker
askIOWorker = quasarIOWorker <$> askQuasar

askExceptionSink :: MonadQuasar m => m ExceptionSink
askExceptionSink = quasarExceptionSink <$> askQuasar

askResourceManager :: MonadQuasar m => m ResourceManager
askResourceManager = quasarResourceManager <$> askQuasar


liftQuasarIO :: (MonadIO m, MonadQuasar m) => QuasarIO a -> m a
liftQuasarIO fn = do
  quasar <- askQuasar
  liftIO $ runReaderT fn quasar

runQuasarIO :: MonadIO m => Quasar -> QuasarIO a -> m a
runQuasarIO quasar fn = liftIO $ runReaderT fn quasar
{-# SPECIALIZE runQuasarIO :: Quasar -> QuasarIO a -> IO a #-}

runQuasarSTM :: MonadSTM m => Quasar -> QuasarSTM a -> m a
runQuasarSTM quasar (QuasarSTM fn) = liftSTM $ runReaderT fn quasar
{-# SPECIALIZE runQuasarSTM :: Quasar -> QuasarSTM a -> STM a #-}

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
  quasar <- askQuasar
  atomically $ runReaderT fn quasar
{-# SPECIALIZE quasarAtomically :: QuasarSTM a -> QuasarIO a #-}


redirectExceptionToSink :: MonadQuasar m => m a -> m (Maybe a)
redirectExceptionToSink fn = do
  exChan <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> ensureSTM (Nothing <$ throwToExceptionSink exChan ex)
{-# SPECIALIZE redirectExceptionToSink :: QuasarIO a -> QuasarIO (Maybe a) #-}
{-# SPECIALIZE redirectExceptionToSink :: QuasarSTM a -> QuasarSTM (Maybe a) #-}

redirectExceptionToSink_ :: MonadQuasar m => m a -> m ()
redirectExceptionToSink_ fn = void $ redirectExceptionToSink fn
{-# SPECIALIZE redirectExceptionToSink_ :: QuasarIO a -> QuasarIO () #-}
{-# SPECIALIZE redirectExceptionToSink_ :: QuasarSTM a -> QuasarSTM () #-}


-- * Quasar initialization

withQuasarGeneric :: Logger -> TIOWorker -> ExceptionSink -> QuasarIO a -> IO a
withQuasarGeneric logger worker exChan fn = mask \unmask -> do
  rm <- atomically $ newUnmanagedResourceManagerSTM worker exChan
  let quasar = Quasar logger worker exChan rm
  unmask (runQuasarIO quasar fn) `finally` dispose rm
