module Quasar.Resources.Disposer (
  TDisposer,
  newTDisposer,
  disposeTDisposer,
) where

import Quasar.Prelude
import {-# SOURCE #-} Quasar.Future

data TDisposer
instance Monoid TDisposer
instance Semigroup TDisposer
instance ToFuture '[] () TDisposer

newTDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TDisposer
disposeTDisposer :: MonadSTMc NoRetry '[] m => TDisposer -> m ()
