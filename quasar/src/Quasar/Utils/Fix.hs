module Quasar.Utils.Fix (
  mfixExtra,
  mfixTVar,
) where

import Quasar.Prelude

mfixExtra :: MonadFix m => (a -> m (r, a)) -> m r
mfixExtra fn = do
  (x, _) <- mfix \tuple -> fn (snd tuple)
  pure x

mfixTVar :: (MonadFix m, MonadSTMc NoRetry '[] m) => (TVar a -> m (r, a)) -> m r
mfixTVar fn = do
  (x, _) <- mfix \tuple -> fn =<< newTVar (snd tuple)
  pure x
