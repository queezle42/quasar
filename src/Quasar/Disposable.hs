module Quasar.Disposable (
  IsDisposable(..),
  Disposable,
  disposeIO,
  mkDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Quasar.Core

