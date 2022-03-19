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
  liftQuasarIO,
  quasarAtomically,

  startShortIO_,

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
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO
import Data.Bifunctor (first)


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the channel
data Quasar = Quasar TIOWorker ExceptionSink ResourceManager

instance Resource Quasar where
  getDisposer (Quasar _ _ rm) = getDisposer rm

instance HasField "ioWorker" Quasar TIOWorker where
  getField = quasarIOWorker

instance HasField "exceptionSink" Quasar ExceptionSink where
  getField = quasarExceptionSink

instance HasField "resourceManager" Quasar ResourceManager where
  getField = quasarResourceManager

quasarIOWorker :: Quasar -> TIOWorker
quasarIOWorker (Quasar worker _ _) = worker

quasarExceptionSink :: Quasar -> ExceptionSink
quasarExceptionSink (Quasar _ exChan _) = exChan

quasarResourceManager :: Quasar -> ResourceManager
quasarResourceManager (Quasar _ _ rm) = rm

newResourceScopeSTM :: Quasar -> STM Quasar
newResourceScopeSTM parent = do
  rm <- newUnmanagedResourceManagerSTM worker parentExceptionSink
  attachResource (quasarResourceManager parent) rm
  pure $ Quasar worker (ExceptionSink (disposeOnException rm)) rm
  where
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
  startShortIO :: ShortIO a -> m (Future a)
  ensureSTM :: STM a -> m a
  ensureQuasarSTM :: QuasarSTM a -> m a
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO

newtype QuasarSTM a = QuasarSTM (ReaderT (Quasar, TVar (Future ())) STM a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadFix, Alternative, MonadSTM)


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  {-# SPECIALIZE instance MonadQuasar QuasarIO #-}
  askQuasar = ask
  ensureSTM t = liftIO (atomically t)
  maskIfRequired = mask_
  startShortIO fn = do
    exChan <- askExceptionSink
    liftIO $ uninterruptibleMask_ $ try (runShortIO fn) >>= \case
      Left ex -> do
        atomically $ throwToExceptionSink exChan ex
        pure $ throwM $ toException $ AsyncException ex
      Right result -> pure $ pure result
  ensureQuasarSTM = quasarAtomically
  localQuasar quasar = local (const quasar)


instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM (asks fst)
  ensureSTM fn = QuasarSTM (lift fn)
  maskIfRequired = id
  startShortIO fn = do
    (quasar, effectFutureVar) <- QuasarSTM ask
    let
      worker = quasarIOWorker quasar
      exChan = quasarExceptionSink quasar

    ensureSTM do
      awaitable <- startShortIOSTM fn worker exChan
      -- Await in reverse order, so it is almost guaranteed this only retries once
      modifyTVar effectFutureVar (awaitSuccessOrFailure awaitable *>)
      pure awaitable
  ensureQuasarSTM = id
  localQuasar quasar (QuasarSTM fn) = QuasarSTM (local (first (const quasar)) fn)


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  ensureSTM t = lift (ensureSTM t)
  maskIfRequired fn = do
    x <- ask
    lift $ maskIfRequired (runReaderT fn x)
  startShortIO t = lift (startShortIO t)
  ensureQuasarSTM t = lift (ensureQuasarSTM t)
  localQuasar quasar fn = do
    x <- ask
    lift (localQuasar quasar (runReaderT fn x))

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...


startShortIO_ :: MonadQuasar m => ShortIO () -> m ()
startShortIO_ fn = void $ startShortIO fn

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

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
 quasar <- askQuasar
 liftIO do
   await =<< atomically do
     effectFutureVar <- newTVar (pure ())
     result <- runReaderT fn (quasar, effectFutureVar)
     (result <$) <$> readTVar effectFutureVar
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

withQuasarGeneric :: TIOWorker -> ExceptionSink -> QuasarIO a -> IO a
withQuasarGeneric worker exChan fn = mask \unmask -> do
  rm <- atomically $ newUnmanagedResourceManagerSTM worker exChan
  let quasar = Quasar worker exChan rm
  unmask (runQuasarIO quasar fn) `finally` dispose rm
