{-# LANGUAGE UndecidableInstances #-}

module Quasar.MonadQuasar (
  -- * Quasar
  Quasar,
  newQuasar,
  withQuasar,
  newResourceScope,
  newResourceScopeIO,
  newResourceScopeSTM,
  withResourceScope,
  --catchQuasar,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,
  QuasarSTMc,

  runQuasarIO,
  runQuasarSTM,
  runQuasarSTMc,
  liftQuasarIO,
  liftQuasarSTM,
  liftQuasarSTMc,
  quasarAtomically,
  quasarAtomicallyC,

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
import Quasar.Future
import Quasar.Logger
import Quasar.Prelude
import Quasar.Resources.Disposer
import Control.Monad.Base (MonadBase)


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the channel
data Quasar = Quasar Logger TIOWorker ExceptionSink ResourceManager

instance Resource Quasar where
  toDisposer (Quasar _ _ _ rm) = toDisposer rm

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

newResourceScopeSTM :: MonadSTMc NoRetry '[FailedToAttachResource] m => Quasar -> m Quasar
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
    disposeOnException :: ResourceManager -> SomeException -> STMc NoRetry '[] ()
    disposeOnException rm ex = do
      disposeEventually_ rm
      throwToExceptionSink parentExceptionSink ex

newResourceScope :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => m Quasar
newResourceScope = liftSTMc @NoRetry @'[FailedToAttachResource] . newResourceScopeSTM =<< askQuasar
{-# SPECIALIZE newResourceScope :: QuasarSTM Quasar #-}

newResourceScopeIO :: (MonadQuasar m, MonadIO m) => m Quasar
newResourceScopeIO = quasarAtomically newResourceScope
{-# SPECIALIZE newResourceScopeIO :: QuasarIO Quasar #-}


withResourceScope :: (MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
withResourceScope fn = bracket newResourceScopeIO dispose (`localQuasar` fn)
{-# SPECIALIZE withResourceScope :: QuasarIO a -> QuasarIO a #-}


class (MonadFix m, ResourceCollector m) => MonadQuasar m where
  askQuasar :: m Quasar
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar

newtype QuasarIO a = QuasarIO (QuasarT IO a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, Throw e, ThrowEx, MonadMask, MonadFail, MonadFix, Alternative, MonadPlus, MonadBase IO, MonadIO)

instance Semigroup a => Semigroup (QuasarIO a) where
  fx <> fy = liftA2 (<>) fx fy

instance Monoid a => Monoid (QuasarIO a) where
  mempty = pure mempty

instance MonadLog QuasarIO where
  logMessage message = do
    logger <- askLogger
    liftIO $ logger message

instance MonadAwait QuasarIO where
  await awaitable = liftIO (await awaitable)

instance ResourceCollector QuasarIO where
  collectResource resource = do
    rm <- askResourceManager
    atomically $ attachResource rm resource


newtype QuasarSTM a = QuasarSTM (QuasarT STM a)
  deriving newtype (Functor, Applicative, Monad, MonadRetry, MonadThrow, MonadCatch, Throw e, ThrowEx, MonadFix, Alternative, MonadPlus, MonadSTMcBase)

instance Semigroup a => Semigroup (QuasarSTM a) where
  fx <> fy = liftA2 (<>) fx fy

instance Monoid a => Monoid (QuasarSTM a) where
  mempty = pure mempty

instance ResourceCollector QuasarSTM where
  collectResource resource = do
    rm <- askResourceManager
    attachResource rm resource


newtype QuasarSTMc canRetry exceptions a = QuasarSTMc (QuasarT (STMc canRetry exceptions) a)
  deriving newtype (
    Applicative,
    Functor,
    Monad,
    MonadCatch,
    MonadFail,
    MonadFix,
    MonadSTMcBase,
    MonadThrow,
    Throw e,
    ThrowEx
  )

deriving newtype instance MonadRetry (QuasarSTMc Retry exceptions)
deriving newtype instance Alternative (QuasarSTMc Retry exceptions)
deriving newtype instance MonadPlus (QuasarSTMc Retry exceptions)

instance Semigroup a => Semigroup (QuasarSTMc canRetry exceptions a) where
  (<>) = liftA2 (<>)

instance Monoid a => Monoid (QuasarSTMc canRetry exceptions a) where
  mempty = pure mempty



instance MonadQuasar QuasarIO where
  askQuasar = QuasarIO ask
  localQuasar quasar (QuasarIO fn) = QuasarIO (local (const quasar) fn)

instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM ask
  localQuasar quasar (QuasarSTM fn) = QuasarSTM (local (const quasar) fn)

instance ResourceCollector (QuasarSTMc canRetry exceptions) =>
  MonadQuasar (QuasarSTMc canRetry exceptions) where
  askQuasar = QuasarSTMc ask
  localQuasar quasar (QuasarSTMc fn) = QuasarSTMc (local (const quasar) fn)

instance FailedToAttachResource :< exceptions => ResourceCollector (QuasarSTMc canRetry exceptions) where
  collectResource resource = do
    rm <- askResourceManager
    attachResource rm resource




instance MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  localQuasar quasar fn = do
    x <- ask
    lift (localQuasar quasar (runReaderT fn x))

instance ResourceCollector m => ResourceCollector (ReaderT r m) where
  collectResource = lift . collectResource

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

liftQuasarSTMc :: forall canRetry exceptions m a. (MonadSTMc canRetry exceptions m, MonadQuasar m) => QuasarSTMc canRetry exceptions a -> m a
liftQuasarSTMc fn = do
  quasar <- askQuasar
  runQuasarSTMc @canRetry @exceptions quasar fn
{-# RULES "liftQuasarSTMc/id" liftQuasarSTMc = id #-}
{-# INLINABLE [1] liftQuasarSTMc #-}

runQuasarIO :: MonadIO m => Quasar -> QuasarIO a -> m a
runQuasarIO quasar (QuasarIO fn) = liftIO $ runReaderT fn quasar
{-# INLINABLE runQuasarIO #-}

runQuasarSTM :: MonadSTM m => Quasar -> QuasarSTM a -> m a
runQuasarSTM quasar (QuasarSTM fn) = liftSTM $ runReaderT fn quasar
{-# INLINABLE runQuasarSTM #-}

runQuasarSTMc :: forall canRetry exceptions m a. MonadSTMc canRetry exceptions m => Quasar -> QuasarSTMc canRetry exceptions a -> m a
runQuasarSTMc quasar (QuasarSTMc fn) = liftSTMc $ runReaderT fn quasar
{-# INLINABLE runQuasarSTMc #-}

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
  quasar <- askQuasar
  atomically $ runReaderT fn quasar
{-# INLINABLE quasarAtomically #-}

quasarAtomicallyC :: (MonadQuasar m, MonadIO m) => QuasarSTMc Retry '[SomeException] a -> m a
quasarAtomicallyC (QuasarSTMc fn) = do
  quasar <- askQuasar
  atomicallyC $ runReaderT fn quasar
{-# INLINABLE quasarAtomicallyC #-}


redirectExceptionToSink :: (MonadCatch m, MonadQuasar m, MonadSTM m) => m a -> m (Maybe a)
redirectExceptionToSink fn = do
  exChan <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> liftSTM (Nothing <$ throwToExceptionSink exChan ex)

redirectExceptionToSinkIO :: (MonadCatch m, MonadQuasar m, MonadIO m) => m a -> m (Maybe a)
redirectExceptionToSinkIO fn = do
  exChan <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> atomically (Nothing <$ throwToExceptionSink exChan ex)
{-# SPECIALIZE redirectExceptionToSinkIO :: QuasarIO a -> QuasarIO (Maybe a) #-}

redirectExceptionToSink_ :: (MonadCatch m, MonadQuasar m, MonadSTM m) => m a -> m ()
redirectExceptionToSink_ fn = void $ redirectExceptionToSink fn

redirectExceptionToSinkIO_ :: (MonadCatch m, MonadQuasar m, MonadIO m) => m a -> m ()
redirectExceptionToSinkIO_ fn = void $ redirectExceptionToSinkIO fn
{-# SPECIALIZE redirectExceptionToSinkIO_ :: QuasarIO a -> QuasarIO () #-}


--catchQuasar :: forall e m a. (MonadQuasar m, Exception e) => (e -> STM' NoRetry CanThrow ()) -> m a -> m a
--catchQuasar handler fn = do
--  exSink <- catchSink handler <$> askExceptionSink
--  replaceExceptionSink exSink fn

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
