module Quasar.Utils.ExtraT (
  ExtraT(..),
  Extra(..),
) where

-- Use prelude from `base` to prevent module import cycle. This allows using ExtraT in PreludeExtras.
import Prelude

import Data.Bifunctor

newtype ExtraT s m r = ExtraT {
  runExtraT :: m (r, s)
}
instance Functor m => Functor (ExtraT s m) where
  fmap :: (a -> b) -> ExtraT s m a -> ExtraT s m b
  fmap fn = ExtraT . fmap (first fn) . runExtraT

newtype Extra s r = Extra {
  runExtra :: (r, s)
}
instance Functor (Extra s) where
  fmap :: (a -> b) -> Extra s a -> Extra s b
  fmap fn = Extra . first fn . runExtra
