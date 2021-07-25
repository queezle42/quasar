module Quasar.Disposable (
  IsDisposable(..),
  Disposable,
  mkDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Quasar.Core
import Quasar.Prelude

-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource.
  dispose :: a -> AsyncIO ()

  -- | Dispose a resource in the IO monad.
  disposeIO :: a -> IO ()
  disposeIO = runAsyncIO . dispose

  toDisposable :: a -> Disposable
  toDisposable = mkDisposable . dispose

instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose
  disposeIO = mapM_ disposeIO


newtype Disposable = Disposable (AsyncIO ())

instance IsDisposable Disposable where
  dispose (Disposable fn) = fn
  toDisposable = id

instance Semigroup Disposable where
  x <> y = mkDisposable $ liftA2 (<>) (dispose x) (dispose y)

instance Monoid Disposable where
  mempty = mkDisposable $ pure ()
  mconcat disposables = mkDisposable $ traverse_ dispose disposables


mkDisposable :: AsyncIO () -> Disposable
mkDisposable = Disposable

synchronousDisposable :: IO () -> Disposable
synchronousDisposable = mkDisposable . liftIO

noDisposable :: Disposable
noDisposable = mempty
