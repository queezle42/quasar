module Quasar.MonadQuasar (
  -- * Quasar
  Quasar,
  newQuasar,
  withQuasar,
  newResourceScope,
  newResourceScopeIO,
  newResourceScopeSTM,
  withResourceScope,
  catchQuasar,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,

  runQuasarIO,
  runQuasarSTM,
  liftQuasarIO,
  liftQuasarSTM,
  quasarAtomically,

  -- ** Utils
  redirectExceptionToSink,
  redirectExceptionToSinkIO,
  redirectExceptionToSink_,
  redirectExceptionToSinkIO_,

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
  pure $ newQuasar logger worker parentExceptionSink rm
  where
    logger = quasarLogger parent
    worker = quasarIOWorker parent
    parentExceptionSink = quasarExceptionSink parent

-- | Construct a quasar, ensuring the Quasar invarinat, i.e. when an exception is thrown to the quasar, the provided resource manager will be disposed.
newQuasar :: Logger -> TIOWorker -> ExceptionSink -> ResourceManager -> Quasar
newQuasar logger worker parentExceptionSink resourceManager = do
  Quasar logger worker (ExceptionSink (disposeOnException resourceManager)) resourceManager
  where
    disposeOnException :: ResourceManager -> SomeException -> STM ()
    disposeOnException rm ex = do
      disposeEventuallySTM_ rm
      throwToExceptionSink parentExceptionSink ex

newResourceScope :: (MonadQuasar m, MonadSTM m) => m Quasar
newResourceScope = liftSTM . newResourceScopeSTM =<< askQuasar
{-# SPECIALIZE newResourceScope :: QuasarSTM Quasar #-}

newResourceScopeIO :: (MonadQuasar m, MonadIO m) => m Quasar
newResourceScopeIO = quasarAtomically newResourceScope
{-# SPECIALIZE newResourceScopeIO :: QuasarIO Quasar #-}


withResourceScope :: (MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
withResourceScope fn = bracket newResourceScopeIO dispose (`localQuasar` fn)
{-# SPECIALIZE withResourceScope :: QuasarIO a -> QuasarIO a #-}


class (MonadCatch m, MonadFix m) => MonadQuasar m where
  askQuasar :: m Quasar
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO

newtype QuasarSTM a = QuasarSTM (QuasarT STM a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadFix, Alternative, MonadSTM)


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  askQuasar = ask
  localQuasar quasar = local (const quasar)
  {-# SPECIALIZE instance MonadQuasar QuasarIO #-}

instance (MonadIO m, MonadMask m, MonadFix m) => MonadLog (QuasarT m) where
  logMessage msg = do
    logger <- askLogger
    liftIO $ logger msg
  {-# SPECIALIZE instance MonadLog QuasarIO #-}


instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM ask
  localQuasar quasar (QuasarSTM fn) = QuasarSTM (local (const quasar) fn)


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
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
  liftIO $ runQuasarIO quasar fn
{-# RULES "liftQuasarIO/id" liftQuasarIO = id #-}
{-# INLINABLE [1] liftQuasarIO #-}

liftQuasarSTM :: (MonadSTM m, MonadQuasar m) => QuasarSTM a -> m a
liftQuasarSTM fn = do
  quasar <- askQuasar
  liftSTM $ runQuasarSTM quasar fn
{-# RULES "liftQuasarSTM/id" liftQuasarSTM = id #-}
{-# INLINABLE [1] liftQuasarSTM #-}

runQuasarIO :: MonadIO m => Quasar -> QuasarIO a -> m a
runQuasarIO quasar fn = liftIO $ runReaderT fn quasar
{-# SPECIALIZE runQuasarIO :: Quasar -> QuasarIO a -> IO a #-}
{-# INLINABLE runQuasarIO #-}

runQuasarSTM :: MonadSTM m => Quasar -> QuasarSTM a -> m a
runQuasarSTM quasar (QuasarSTM fn) = liftSTM $ runReaderT fn quasar
{-# SPECIALIZE runQuasarSTM :: Quasar -> QuasarSTM a -> STM a #-}
{-# INLINABLE runQuasarSTM #-}

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
  quasar <- askQuasar
  atomically $ runReaderT fn quasar
{-# SPECIALIZE quasarAtomically :: QuasarSTM a -> QuasarIO a #-}
{-# INLINABLE quasarAtomically #-}


redirectExceptionToSink :: (MonadQuasar m, MonadSTM m) => m a -> m (Maybe a)
redirectExceptionToSink fn = do
  exChan <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> liftSTM (Nothing <$ throwToExceptionSink exChan ex)
{-# SPECIALIZE redirectExceptionToSink :: QuasarSTM a -> QuasarSTM (Maybe a) #-}

redirectExceptionToSinkIO :: (MonadQuasar m, MonadIO m) => m a -> m (Maybe a)
redirectExceptionToSinkIO fn = do
  exChan <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> atomically (Nothing <$ throwToExceptionSink exChan ex)
{-# SPECIALIZE redirectExceptionToSinkIO :: QuasarIO a -> QuasarIO (Maybe a) #-}

redirectExceptionToSink_ :: (MonadQuasar m, MonadSTM m) => m a -> m ()
redirectExceptionToSink_ fn = void $ redirectExceptionToSink fn
{-# SPECIALIZE redirectExceptionToSink_ :: QuasarSTM a -> QuasarSTM () #-}

redirectExceptionToSinkIO_ :: (MonadQuasar m, MonadIO m) => m a -> m ()
redirectExceptionToSinkIO_ fn = void $ redirectExceptionToSinkIO fn
{-# SPECIALIZE redirectExceptionToSinkIO_ :: QuasarIO a -> QuasarIO () #-}


catchQuasar :: MonadQuasar m => forall e. Exception e => (e -> STM ()) -> m a -> m a
catchQuasar handler fn = do
  exSink <- catchSink handler <$> askExceptionSink
  replaceExceptionSink exSink fn

replaceExceptionSink :: MonadQuasar m => ExceptionSink -> m a -> m a
replaceExceptionSink exSink fn = do
  quasar <- askQuasar
  let q = newQuasar (quasarLogger quasar) (quasarIOWorker quasar) exSink (quasarResourceManager quasar)
  localQuasar q fn

-- * Quasar initialization

withQuasar :: Logger -> TIOWorker -> ExceptionSink -> QuasarIO a -> IO a
withQuasar logger worker exChan fn = mask \unmask -> do
  rm <- atomically $ newUnmanagedResourceManagerSTM worker exChan
  let quasar = newQuasar logger worker exChan rm
  unmask (runQuasarIO quasar fn) `finally` dispose rm
