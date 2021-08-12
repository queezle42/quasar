module Quasar.Disposable (
  IsDisposable(..),
  Disposable,
  disposeIO,
  newDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Quasar.Core

