{-# LANGUAGE UndecidableInstances #-}

module Quasar.MonadQuasar (
  -- * Quasar
  Quasar,
  newQuasar,
  withQuasar,
  newResourceScope,
  newResourceScopeIO,
  newResourceScopeSTM,
  newOrClosedResourceScopeSTM,
  withResourceScope,
  catchQuasar,
  replaceExceptionSink,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,
  QuasarSTMc,

  runQuasarIO,
  runQuasarSTM,
  runQuasarSTMc,
  runQuasarSTMc',
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
  quasarExceptionSink,
  quasarResourceManager,
  askExceptionSink,
  askResourceManager,
) where

import Control.Monad (MonadPlus)
import Control.Monad.Trans (lift)
import Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask, bracket, catchAll, mask, finally)
import Control.Monad.Reader (ReaderT, runReaderT, ask, local)
import GHC.Records (HasField(..))
import Quasar.Exceptions
import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Disposer


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the sink
data Quasar = Quasar ExceptionSink ResourceManager

instance Disposable Quasar where
  getDisposer (Quasar _ rm) = getDisposer rm

instance HasField "exceptionSink" Quasar ExceptionSink where
  getField = quasarExceptionSink

instance HasField "resourceManager" Quasar ResourceManager where
  getField = quasarResourceManager

quasarExceptionSink :: Quasar -> ExceptionSink
quasarExceptionSink (Quasar sink _) = sink

quasarResourceManager :: Quasar -> ResourceManager
quasarResourceManager (Quasar _ rm) = rm

newResourceScopeSTM :: (MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => Quasar -> m Quasar
newResourceScopeSTM parent = do
  rm <- newUnmanagedResourceManagerSTM
  attachResource (quasarResourceManager parent) rm
  pure $ newQuasar parentExceptionSink rm
  where
    parentExceptionSink = quasarExceptionSink parent

newOrClosedResourceScopeSTM :: MonadSTMc NoRetry '[] m => Quasar -> m Quasar
newOrClosedResourceScopeSTM parent =
  catchSTMc @NoRetry @'[FailedToAttachResource]
    (newResourceScopeSTM parent)
    \FailedToAttachResource -> pure parent

-- | Construct a quasar, ensuring the Quasar invarinat, i.e. when an exception is thrown to the quasar, the provided resource manager will be disposed.
newQuasar :: ExceptionSink -> ResourceManager -> Quasar
newQuasar parentExceptionSink resourceManager = do
  Quasar (ExceptionSink (disposeOnException resourceManager)) resourceManager
  where
    disposeOnException :: ResourceManager -> SomeException -> STMc NoRetry '[] ()
    disposeOnException rm ex = do
      disposeEventually_ rm
      throwToExceptionSink parentExceptionSink ex

newResourceScope :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => m Quasar
newResourceScope = liftSTMc @NoRetry @'[FailedToAttachResource] . newResourceScopeSTM =<< askQuasar
{-# SPECIALIZE newResourceScope :: QuasarSTM Quasar #-}

newResourceScopeIO :: (MonadQuasar m, MonadIO m, HasCallStack) => m Quasar
newResourceScopeIO = quasarAtomically newResourceScope
{-# SPECIALIZE newResourceScopeIO :: QuasarIO Quasar #-}


withResourceScope :: (MonadQuasar m, MonadIO m, MonadMask m, HasCallStack) => m a -> m a
withResourceScope fn = bracket newResourceScopeIO dispose (`localQuasar` fn)
{-# SPECIALIZE withResourceScope :: QuasarIO a -> QuasarIO a #-}


class (MonadFix m, ResourceCollector m) => MonadQuasar m where
  askQuasar :: m Quasar
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar

newtype QuasarIO a = QuasarIO (QuasarT IO a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, Throw e, MonadThrowEx, MonadMask, MonadFail, MonadFix, Alternative, MonadPlus, MonadIO)

instance Semigroup a => Semigroup (QuasarIO a) where
  fx <> fy = liftA2 (<>) fx fy

instance Monoid a => Monoid (QuasarIO a) where
  mempty = pure mempty

instance MonadAwait QuasarIO where
  await awaitable = liftIO (await awaitable)

instance ResourceCollector QuasarIO where
  collectResource resource = do
    rm <- askResourceManager
    atomically $ attachResource rm resource


newtype QuasarSTM a = QuasarSTM (QuasarT STM a)
  deriving newtype (Functor, Applicative, Monad, MonadRetry, MonadThrow, MonadCatch, Throw e, MonadThrowEx, MonadFix, Alternative, MonadPlus, MonadSTMcBase)

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
    MonadFix,
    MonadSTMcBase,
    MonadThrowEx
  )

deriving newtype instance (Exception e, e :< exceptions) => Throw e (QuasarSTMc canRetry exceptions)
deriving newtype instance SomeException :< exceptions => MonadThrow (QuasarSTMc canRetry exceptions)
deriving newtype instance SomeException :< exceptions => MonadCatch (QuasarSTMc canRetry exceptions)
deriving newtype instance IOException :< exceptions => MonadFail (QuasarSTMc canRetry exceptions)
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

runQuasarSTMc' :: forall canRetry exceptions a. Quasar -> QuasarSTMc canRetry exceptions a -> STMc canRetry exceptions a
runQuasarSTMc' quasar (QuasarSTMc fn) = runReaderT fn quasar
{-# INLINABLE runQuasarSTMc' #-}

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
  sink <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> liftSTM (Nothing <$ throwToExceptionSink sink ex)

redirectExceptionToSinkIO :: (MonadCatch m, MonadQuasar m, MonadIO m) => m a -> m (Maybe a)
redirectExceptionToSinkIO fn = do
  sink <- askExceptionSink
  (Just <$> fn) `catchAll`
    \ex -> atomically (Nothing <$ throwToExceptionSink sink ex)
{-# SPECIALIZE redirectExceptionToSinkIO :: QuasarIO a -> QuasarIO (Maybe a) #-}

redirectExceptionToSink_ :: (MonadCatch m, MonadQuasar m, MonadSTM m) => m a -> m ()
redirectExceptionToSink_ fn = void $ redirectExceptionToSink fn

redirectExceptionToSinkIO_ :: (MonadCatch m, MonadQuasar m, MonadIO m) => m a -> m ()
redirectExceptionToSinkIO_ fn = void $ redirectExceptionToSinkIO fn
{-# SPECIALIZE redirectExceptionToSinkIO_ :: QuasarIO a -> QuasarIO () #-}


-- TODO the name does not properly reflect the functionality, and the
-- functionality is questionable (but already used in quasar-network).
-- Current behavior: exceptions on the current thread are not handled.
catchQuasar :: forall e m a. (MonadQuasar m, Exception e) => (e -> STMc NoRetry '[SomeException] ()) -> m a -> m a
catchQuasar handler fn = do
  sink <- catchSink handler <$> askExceptionSink
  replaceExceptionSink sink fn

replaceExceptionSink :: MonadQuasar m => ExceptionSink -> m a -> m a
replaceExceptionSink sink fn = do
  quasar <- askQuasar
  let q = newQuasar sink (quasarResourceManager quasar)
  localQuasar q fn

-- * Quasar initialization

withQuasar :: ExceptionSink -> QuasarIO a -> IO a
withQuasar sink fn = mask \unmask -> do
  rm <- atomically $ newUnmanagedResourceManagerSTM
  let quasar = newQuasar sink rm
  unmask (runQuasarIO quasar fn) `finally` dispose rm
