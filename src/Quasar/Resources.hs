module Quasar.Resources (
  -- * Resources
  Resource(..),
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  isDisposed,

  -- * Disposer
  Disposer,

  -- * Resource manager
  ResourceManager,
  newResourceManagerSTM,
  attachResource,
) where


import Control.Concurrent.STM
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Disposer



