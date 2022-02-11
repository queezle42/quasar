module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  isDisposed,

  -- * Monadic resource management
  registerResource,
  registerDisposeAction,
  registerDisposeTransaction,

  -- * Disposer
  Disposer,
  newIODisposer,
  newSTMDisposer,

  -- * Resource manager
  ResourceManager,
  newResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent.STM
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
