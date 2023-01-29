module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,

  -- * ResourceCollector
  ResourceCollector(..),

  -- * Resource management in the `Quasar` monad
  registerDisposeAction,
  registerDisposeAction_,
  registerDisposeActionIO,
  registerDisposeActionIO_,
  registerDisposeTransaction,
  registerDisposeTransaction_,
  registerDisposeTransactionIO,
  registerDisposeTransactionIO_,
  registerSimpleDisposeTransaction,
  registerSimpleDisposeTransaction_,
  registerSimpleDisposeTransactionIO,
  registerSimpleDisposeTransactionIO_,
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
  registerNewResource_,
  disposeOnError,

  -- * Types to implement resources
  -- ** Disposer
  Disposer,
  TDisposer,
  TSimpleDisposer,
  disposeTDisposer,
  disposeTSimpleDisposer,
  newUnmanagedIODisposer,
  newUnmanagedSTMDisposer,
  newUnmanagedTSimpleDisposer,
  trivialDisposer,

  -- ** Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
  tryAttachResource,
) where


import Control.Monad.Catch
import Quasar.Future
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources.Disposer


registerDisposeAction :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => IO () -> m Disposer
registerDisposeAction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newUnmanagedIODisposer fn worker exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeAction :: IO () -> QuasarSTM Disposer #-}

registerDisposeAction_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => IO () -> m ()
registerDisposeAction_ fn = void $ registerDisposeAction fn

registerDisposeActionIO :: (MonadQuasar m, MonadIO m) => IO () -> m Disposer
registerDisposeActionIO fn = quasarAtomically $ registerDisposeAction fn

registerDisposeActionIO_ :: (MonadQuasar m, MonadIO m) => IO () -> m ()
registerDisposeActionIO_ fn = quasarAtomically $ void $ registerDisposeAction fn

registerDisposeTransaction :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STM () -> m TDisposer
registerDisposeTransaction fn = do
  worker <- askIOWorker
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newUnmanagedSTMDisposer fn worker exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeTransaction :: STM () -> QuasarSTM TDisposer #-}

registerDisposeTransaction_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STM () -> m ()
registerDisposeTransaction_ fn = void $ registerDisposeTransaction fn

registerDisposeTransactionIO :: (MonadQuasar m, MonadIO m) => STM () -> m TDisposer
registerDisposeTransactionIO fn = quasarAtomically $ registerDisposeTransaction fn

registerDisposeTransactionIO_ :: (MonadQuasar m, MonadIO m) => STM () -> m ()
registerDisposeTransactionIO_ fn = quasarAtomically $ void $ registerDisposeTransaction fn

registerSimpleDisposeTransaction :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STMc NoRetry '[] () -> m TSimpleDisposer
registerSimpleDisposeTransaction fn = do
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newUnmanagedTSimpleDisposer fn
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerSimpleDisposeTransaction :: STMc NoRetry '[] () -> QuasarSTM TSimpleDisposer #-}

registerSimpleDisposeTransaction_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STMc NoRetry '[] () -> m ()
registerSimpleDisposeTransaction_ fn = void $ registerSimpleDisposeTransaction fn

registerSimpleDisposeTransactionIO :: (MonadQuasar m, MonadIO m) => STMc NoRetry '[] () -> m TSimpleDisposer
registerSimpleDisposeTransactionIO fn = quasarAtomically $ registerSimpleDisposeTransaction fn

registerSimpleDisposeTransactionIO_ :: (MonadQuasar m, MonadIO m) => STMc NoRetry '[] () -> m ()
registerSimpleDisposeTransactionIO_ fn = quasarAtomically $ void $ registerSimpleDisposeTransaction fn

registerNewResource :: forall a m. (Resource a, MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
registerNewResource fn = do
  rm <- askResourceManager
  disposing <- isJust <$> peekFutureIO (isDisposing rm)
  -- Bail out before creating the resource _if possible_
  when disposing $ throwM AlreadyDisposing

  mask_ do
    resource <- fn
    collectResource resource `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ resource
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwM AlreadyDisposing
        _ -> throwM ex
    pure resource
{-# SPECIALIZE registerNewResource :: Resource a => QuasarIO a -> QuasarIO a #-}

registerNewResource_ :: forall a m. (Resource a, MonadQuasar m, MonadIO m, MonadMask m) => m a -> m ()
registerNewResource_ = void . registerNewResource


disposeEventuallyIO :: (Resource r, MonadIO m) => r -> m (Future ())
disposeEventuallyIO res = atomically $ disposeEventually res

disposeEventuallyIO_ :: (Resource r, MonadIO m) => r -> m ()
disposeEventuallyIO_ res = atomically $ void $ disposeEventually res


captureResources :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => m a -> m (a, Disposer)
captureResources fn = do
  quasar <- newResourceScope
  localQuasar quasar do
    result <- fn
    pure (result, toDisposer (quasarResourceManager quasar))

captureResources_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => m () -> m Disposer
captureResources_ fn = snd <$> captureResources fn

captureResourcesIO :: (MonadQuasar m, MonadIO m) => m a -> m (a, Disposer)
captureResourcesIO fn = do
  quasar <- newResourceScopeIO
  localQuasar quasar do
    result <- fn
    pure (result, toDisposer (quasarResourceManager quasar))

captureResourcesIO_ :: (MonadQuasar m, MonadIO m) => m () -> m Disposer
captureResourcesIO_ fn = snd <$> captureResourcesIO fn



-- | Runs the computation in a new resource scope, which is disposed when an exception happenes. When the computation succeeds, resources are kept.
disposeOnError :: (MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
disposeOnError fn = mask \unmask -> do
  quasar <- newResourceScopeIO
  unmask (localQuasar quasar fn) `onError` dispose quasar
