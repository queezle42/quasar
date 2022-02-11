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

  -- * STM
  disposeEventuallySTM,
  disposeEventuallySTM_,

  -- * Types to implement resources
  -- ** Disposer
  Disposer,
  newIODisposer,
  newSTMDisposer,

  -- ** Resource manager
  ResourceManager,
  newResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Monad
import Quasar.Prelude
import Quasar.Resources.Disposer


newIODisposer :: TIOWorker -> ExceptionChannel -> IO () -> STM Disposer
newIODisposer = undefined

newSTMDisposer :: TIOWorker -> ExceptionChannel -> STM () -> STM Disposer
newSTMDisposer = undefined


registerResource :: (Resource a, MonadQuasar m) => a -> m ()
registerResource resource = do
  rm <- askResourceManager
  runSTM $ attachResource rm resource

registerDisposeAction :: MonadQuasar m => IO () -> m ()
registerDisposeAction fn = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  rm <- askResourceManager
  runSTM $ attachResource rm =<< newIODisposer worker exChan fn

registerDisposeTransaction :: MonadQuasar m => STM () -> m ()
registerDisposeTransaction fn = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  rm <- askResourceManager
  runSTM $ attachResource rm =<< newSTMDisposer worker exChan fn

registerNewResource :: forall a m. (Resource a, MonadQuasar m) => m a -> m a
registerNewResource fn = do
  rm <- askResourceManager
  disposing <- isJust <$> runSTM (peekAwaitableSTM (isDisposing rm))
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
disposeEventually res = runSTM $ disposeEventuallySTM res

disposeEventually_ :: (Resource r, MonadQuasar m) => r -> m ()
disposeEventually_ res = runSTM $ disposeEventuallySTM_ res
