module Quasar.Utils.Fix (
  mfixExtra
) where

import Quasar.Prelude

mfixExtra :: MonadFix m => (a -> m (r, a)) -> m r
mfixExtra fn = do
  (x, _) <- mfix \tuple -> fn (snd tuple)
  pure x
