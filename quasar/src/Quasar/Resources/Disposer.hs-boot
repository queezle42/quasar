module Quasar.Resources.Disposer (
  TDisposer,
  newUnmanagedTDisposer,
  disposeTDisposer,
) where

import Quasar.Prelude
import {-# SOURCE #-} Quasar.Future

data TDisposer
instance Monoid TDisposer
instance Semigroup TDisposer
instance ToFuture () TDisposer

newUnmanagedTDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TDisposer
disposeTDisposer :: TDisposer -> STMc NoRetry '[] ()
