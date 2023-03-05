module Quasar.Utils.ShortIO (
  ShortIO,
  runShortIO,
  unsafeShortIO,

  -- ** Some specific functions required internally
) where

import Control.Monad.Catch
import Quasar.Prelude

newtype ShortIO a = ShortIO (IO a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadMask, MonadFix)

runShortIO :: ShortIO a -> IO a
runShortIO (ShortIO fn) = fn

unsafeShortIO :: IO a -> ShortIO a
unsafeShortIO = ShortIO
