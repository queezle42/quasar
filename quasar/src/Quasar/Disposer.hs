module Quasar.Disposer (
  -- * Disposer api
  Disposable(..),
  dispose,
  disposeEventually,
  disposeEventually_,
  disposeEventuallyIO,
  disposeEventuallyIO_,

  -- ** Disposer
  Disposer,
  newDisposer,
  newDisposerIO,
  isDisposed,
  trivialDisposer,
  isTrivialDisposer,

  -- ** STM variants
  TDisposable(..),
  TDisposer,
  disposeTDisposer,
  disposeSTM,
  newTDisposer,
  newSTMDisposer,
  newRetryTDisposer,
  isTrivialTDisposer,

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
  captureResources,
  captureResources_,
  captureResourcesIO,
  captureResourcesIO_,

  -- * IO
  registerNewResource,
  registerNewResource_,
  disposeOnError,

  -- ** Resource manager
  ResourceManager,
  newResourceManager,
  attachResource,
  tryAttachResource,

  -- * Utils
  futureDisposer,
  futureDisposerGeneric,

  -- * Implementing disposers
  IsDisposerElement(..),
  mkDisposer,
  IsTDisposerElement(..),
  mkTDisposer,
) where


import Control.Monad.Catch
import Quasar.Disposer.Core
import Quasar.Exceptions
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Disposer.FutureDisposer


registerDisposeAction :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => IO () -> m Disposer
registerDisposeAction fn = do
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newDisposer fn exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeAction :: IO () -> QuasarSTM Disposer #-}

registerDisposeAction_ :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => IO () -> m ()
registerDisposeAction_ fn = void $ registerDisposeAction fn

registerDisposeActionIO :: HasCallStack => (MonadQuasar m, MonadIO m) => IO () -> m Disposer
registerDisposeActionIO fn = quasarAtomically $ registerDisposeAction fn

registerDisposeActionIO_ :: HasCallStack => (MonadQuasar m, MonadIO m) => IO () -> m ()
registerDisposeActionIO_ fn = quasarAtomically $ void $ registerDisposeAction fn

registerDisposeTransaction :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STM () -> m Disposer
registerDisposeTransaction fn = do
  exChan <- askExceptionSink
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newSTMDisposer fn exChan
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerDisposeTransaction :: STM () -> QuasarSTM Disposer #-}

registerDisposeTransaction_ :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STM () -> m ()
registerDisposeTransaction_ fn = void $ registerDisposeTransaction fn

registerDisposeTransactionIO :: HasCallStack => (MonadQuasar m, MonadIO m) => STM () -> m Disposer
registerDisposeTransactionIO fn = quasarAtomically $ registerDisposeTransaction fn

registerDisposeTransactionIO_ :: HasCallStack => (MonadQuasar m, MonadIO m) => STM () -> m ()
registerDisposeTransactionIO_ fn = quasarAtomically $ void $ registerDisposeTransaction fn

registerSimpleDisposeTransaction :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STMc NoRetry '[] () -> m TDisposer
registerSimpleDisposeTransaction fn = do
  rm <- askResourceManager
  liftSTMc @NoRetry @'[FailedToAttachResource] do
    disposer <- newTDisposer fn
    attachResource rm disposer
    pure disposer
{-# SPECIALIZE registerSimpleDisposeTransaction :: STMc NoRetry '[] () -> QuasarSTM TDisposer #-}

registerSimpleDisposeTransaction_ :: HasCallStack => (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m) => STMc NoRetry '[] () -> m ()
registerSimpleDisposeTransaction_ fn = void $ registerSimpleDisposeTransaction fn

registerSimpleDisposeTransactionIO :: HasCallStack => (MonadQuasar m, MonadIO m) => STMc NoRetry '[] () -> m TDisposer
registerSimpleDisposeTransactionIO fn = quasarAtomically $ registerSimpleDisposeTransaction fn

registerSimpleDisposeTransactionIO_ :: HasCallStack => (MonadQuasar m, MonadIO m) => STMc NoRetry '[] () -> m ()
registerSimpleDisposeTransactionIO_ fn = quasarAtomically $ void $ registerSimpleDisposeTransaction fn

registerNewResource :: forall a m. (Disposable a, MonadQuasar m, MonadIO m, MonadMask m) => m a -> m a
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
{-# SPECIALIZE registerNewResource :: Disposable a => QuasarIO a -> QuasarIO a #-}

registerNewResource_ :: forall a m. (Disposable a, MonadQuasar m, MonadIO m, MonadMask m) => m a -> m ()
registerNewResource_ = void . registerNewResource


disposeEventuallyIO :: (Disposable r, MonadIO m) => r -> m (Future '[] ())
disposeEventuallyIO res = atomically $ disposeEventually res

disposeEventuallyIO_ :: (Disposable r, MonadIO m) => r -> m ()
disposeEventuallyIO_ res = atomically $ void $ disposeEventually res


captureResources :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => m a -> m (a, Disposer)
captureResources fn = do
  quasar <- newResourceScope
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResources_ :: (MonadQuasar m, MonadSTMc NoRetry '[FailedToAttachResource] m, HasCallStack) => m () -> m Disposer
captureResources_ fn = snd <$> captureResources fn

captureResourcesIO :: (MonadQuasar m, MonadIO m, HasCallStack) => m a -> m (a, Disposer)
captureResourcesIO fn = do
  quasar <- newResourceScopeIO
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResourcesIO_ :: (MonadQuasar m, MonadIO m, HasCallStack) => m () -> m Disposer
captureResourcesIO_ fn = snd <$> captureResourcesIO fn



-- | Runs the computation in a new resource scope, which is disposed when an exception happenes. When the computation succeeds, resources are kept.
disposeOnError :: (MonadQuasar m, MonadIO m, MonadMask m, HasCallStack) => m a -> m a
disposeOnError fn = mask \unmask -> do
  quasar <- newResourceScopeIO
  unmask (localQuasar quasar fn) `onError` dispose quasar
