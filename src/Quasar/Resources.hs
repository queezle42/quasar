module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,

  -- * Resource management in the `Quasar` monad
  registerResource,
  registerResourceIO,
  registerDisposeAction,
  registerDisposeAction_,
  registerDisposeActionIO,
  registerDisposeActionIO_,
  registerDisposeTransaction,
  registerDisposeTransaction_,
  registerDisposeTransactionIO,
  registerDisposeTransactionIO_,
  disposeEventually,
  disposeEventually_,
  disposeEventuallyIO,
  disposeEventuallyIO_,
  captureResources,
  captureResources_,
  captureResourcesIO,
  captureResourcesIO_,

  -- * IO
  registerNewResource,
  disposeOnError,

  -- * Types to implement resources
  -- ** Disposer
  Disposer,
  newUnmanagedIODisposer,
  newUnmanagedSTMDisposer,
  trivialDisposer,

  -- ** Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
) where


import Control.Monad.Catch
import Quasar.Future
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO


newUnmanagedIODisposer :: IO () -> TIOWorker -> ExceptionSink -> STM Disposer
-- TODO change TIOWorker behavior for spawning threads, so no `unsafeShortIO` is necessary
newUnmanagedIODisposer fn worker exChan = newUnmanagedPrimitiveDisposer (unsafeShortIO $ forkFuture fn exChan) worker exChan

newUnmanagedSTMDisposer :: STM () -> TIOWorker -> ExceptionSink -> STM Disposer
newUnmanagedSTMDisposer fn worker exChan = newUnmanagedPrimitiveDisposer disposeFn worker exChan
  where
    disposeFn :: ShortIO (Future ())
    disposeFn = unsafeShortIO $ atomically $
      -- Spawn a thread only if the transaction retries
      (pure <$> fn) `orElse` forkAsyncSTM (atomically fn) worker exChan


registerResource :: (Resource a, MonadQuasar m, MonadSTM m) => a -> m ()
registerResource resource = do
  rm <- askResourceManager
  liftSTM $ attachResource rm resource
{-# SPECIALIZE registerResource :: Resource a => a -> QuasarSTM () #-}

registerResourceIO :: (Resource a, MonadQuasar m, MonadIO m) => a -> m ()
registerResourceIO res = quasarAtomically $ registerResource res
{-# SPECIALIZE registerResourceIO :: Resource a => a -> QuasarIO () #-}

registerDisposeAction :: (MonadQuasar m, MonadSTM m) => IO () -> m Disposer
registerDisposeAction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTM do
    disposer <- newUnmanagedIODisposer fn worker exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeAction :: IO () -> QuasarSTM Disposer #-}

registerDisposeAction_ :: (MonadQuasar m, MonadSTM m) => IO () -> m ()
registerDisposeAction_ fn = liftQuasarSTM $ void $ registerDisposeAction fn

registerDisposeActionIO :: (MonadQuasar m, MonadIO m) => IO () -> m Disposer
registerDisposeActionIO fn = quasarAtomically $ registerDisposeAction fn

registerDisposeActionIO_ :: (MonadQuasar m, MonadIO m) => IO () -> m ()
registerDisposeActionIO_ fn = quasarAtomically $ void $ registerDisposeAction fn

registerDisposeTransaction :: (MonadQuasar m, MonadSTM m) => STM () -> m Disposer
registerDisposeTransaction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTM do
    disposer <- newUnmanagedSTMDisposer fn worker exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeTransaction :: STM () -> QuasarSTM Disposer #-}

registerDisposeTransaction_ :: (MonadQuasar m, MonadSTM m) => STM () -> m ()
registerDisposeTransaction_ fn = liftQuasarSTM $ void $ registerDisposeTransaction fn

registerDisposeTransactionIO :: (MonadQuasar m, MonadIO m) => STM () -> m Disposer
registerDisposeTransactionIO fn = quasarAtomically $ registerDisposeTransaction fn

registerDisposeTransactionIO_ :: (MonadQuasar m, MonadIO m) => STM () -> m ()
registerDisposeTransactionIO_ fn = quasarAtomically $ void $ registerDisposeTransaction fn

registerNewResource :: forall a m. (Resource a, MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
registerNewResource fn = do
  rm <- askResourceManager
  disposing <- isJust <$> peekFuture (isDisposing rm)
  -- Bail out before creating the resource _if possible_
  when disposing $ throwM AlreadyDisposing

  mask_ do
    resource <- fn
    registerResourceIO resource `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ resource
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwM AlreadyDisposing
        _ -> throwM ex
    pure resource
{-# SPECIALIZE registerNewResource :: Resource a => QuasarIO a -> QuasarIO a #-}


disposeEventually :: (Resource r, MonadSTM m) => r -> m (Future ())
disposeEventually res = liftSTM $ disposeEventuallySTM res

disposeEventually_ :: (Resource r, MonadSTM m) => r -> m ()
disposeEventually_ res = liftSTM $ disposeEventuallySTM_ res

disposeEventuallyIO :: (Resource r, MonadIO m) => r -> m (Future ())
disposeEventuallyIO res = atomically $ disposeEventually res

disposeEventuallyIO_ :: (Resource r, MonadIO m) => r -> m ()
disposeEventuallyIO_ res = atomically $ void $ disposeEventually res


captureResources :: (MonadQuasar m, MonadSTM m) => m a -> m (a, [Disposer])
captureResources fn = do
  quasar <- newResourceScope
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResources_ :: (MonadQuasar m, MonadSTM m) => m () -> m [Disposer]
captureResources_ fn = snd <$> captureResources fn

captureResourcesIO :: (MonadQuasar m, MonadIO m) => m a -> m (a, [Disposer])
captureResourcesIO fn = do
  quasar <- newResourceScopeIO
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResourcesIO_ :: (MonadQuasar m, MonadIO m) => m () -> m [Disposer]
captureResourcesIO_ fn = snd <$> captureResourcesIO fn



-- | Runs the computation in a new resource scope, which is disposed when an exception happenes. When the computation succeeds, resources are kept.
disposeOnError :: (MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
disposeOnError fn = mask \unmask -> do
  quasar <- newResourceScopeIO
  unmask (localQuasar quasar fn) `onError` dispose quasar
