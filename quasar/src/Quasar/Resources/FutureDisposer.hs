module Quasar.Resources.FutureDisposer (
  futureDisposer,
) where

import Quasar.Prelude
import Quasar.Future
import Quasar.Resources.Disposer
import Quasar.Utils.TOnce

data FutureDisposer = FutureDisposer Unique (TOnce (Future Disposer) (Future [DisposeDependencies]))

instance IsDisposerElement FutureDisposer where
  disposerElementKey (FutureDisposer key _) = key

  disposeEventually# self = do
    beginDispose# self <&> \case
      DisposeResultAwait future -> future
      DisposeResultDependencies deps -> flattenDisposeDependencies deps

  beginDispose# (FutureDisposer key var) = do
    fdeps <- mapFinalizeTOnce var \future -> do

      promise <- newPromise
      callOnceCompleted_ future \disposer -> do
        fdeps <- beginDisposeDisposer disposer
        tryFulfillPromise_ promise fdeps

      pure (join (toFuture promise))

    pure (DisposeResultDependencies (DisposeDependencies key fdeps))

instance ToFuture () FutureDisposer where
  toFuture (FutureDisposer _ var) = do
    deps <- join (toFuture var)
    mapM_ flattenDisposeDependencies deps

instance Disposable FutureDisposer where
  getDisposer x = mkDisposer [x]

futureDisposer :: Future Disposer -> STMc NoRetry '[] Disposer
futureDisposer future = do
  key <- newUniqueSTM
  var <- newTOnce future
  pure (getDisposer (FutureDisposer key var))
