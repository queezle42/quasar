module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,
  isDisposing,
  isDisposed,

  -- * Resource management in the `Quasar` monad
  registerResource,
  registerNewResource,
  registerDisposeAction,
  registerDisposeTransaction,
  disposeEventually,
  disposeEventually_,
  captureResources,
  captureResources_,

  -- * STM
  disposeEventuallySTM,
  disposeEventuallySTM_,

  -- * Types to implement resources
  -- ** Disposer
  Disposer,
  newIODisposerSTM,
  newSTMDisposerSTM,

  -- ** Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Monad
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.ShortIO


newIODisposerSTM :: IO () -> TIOWorker -> ExceptionChannel -> STM Disposer
newIODisposerSTM fn worker exChan = newPrimitiveDisposer (forkAsyncShortIO fn exChan) worker exChan

newSTMDisposerSTM :: STM () -> TIOWorker -> ExceptionChannel -> STM Disposer
newSTMDisposerSTM fn worker exChan = newPrimitiveDisposer disposeFn worker exChan
  where
    disposeFn :: ShortIO (Awaitable ())
    disposeFn = unsafeShortIO $ atomically $
      -- Spawn a thread only if the transaction retries
      (pure <$> fn) `orElse` forkAsyncSTM (atomically fn) worker exChan


registerResource :: (Resource a, MonadQuasar m) => a -> m ()
registerResource resource = do
  rm <- askResourceManager
  ensureSTM $ attachResource rm resource

registerDisposeAction :: MonadQuasar m => IO () -> m ()
registerDisposeAction fn = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  rm <- askResourceManager
  ensureSTM $ attachResource rm =<< newIODisposerSTM fn worker exChan

registerDisposeTransaction :: MonadQuasar m => STM () -> m ()
registerDisposeTransaction fn = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  rm <- askResourceManager
  ensureSTM $ attachResource rm =<< newSTMDisposerSTM fn worker exChan

registerNewResource :: forall a m. (Resource a, MonadQuasar m) => m a -> m a
registerNewResource fn = do
  rm <- askResourceManager
  disposing <- isJust <$> ensureSTM (peekAwaitableSTM (isDisposing rm))
  -- Bail out before creating the resource _if possible_
  when disposing $ throwM AlreadyDisposing

  maskIfRequired do
    resource <- fn
    registerResource resource `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      disposeEventually_ resource
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwM AlreadyDisposing
        _ -> throwM ex
    pure resource


disposeEventually :: (Resource r, MonadQuasar m) => r -> m (Awaitable ())
disposeEventually res = ensureSTM $ disposeEventuallySTM res

disposeEventually_ :: (Resource r, MonadQuasar m) => r -> m ()
disposeEventually_ res = ensureSTM $ disposeEventuallySTM_ res


captureResources :: MonadQuasar m => m a -> m (a, Disposer)
captureResources fn = do
  quasar <- newQuasar
  localQuasar quasar do
    result <- fn
    pure (result, getDisposer (quasarResourceManager quasar))

captureResources_ :: MonadQuasar m => m () -> m Disposer
captureResources_ fn = snd <$> captureResources fn
