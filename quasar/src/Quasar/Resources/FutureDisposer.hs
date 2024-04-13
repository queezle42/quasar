module Quasar.Resources.FutureDisposer (
  futureDisposer,
  futureDisposerGeneric,
) where

import Quasar.Prelude
import Quasar.Future
import Quasar.Resources.Disposer
import Quasar.Utils.TOnce

data FutureDisposer = FutureDisposer Unique (TOnce (Future '[] Disposer) (Future '[] [DisposeDependencies]))

instance IsDisposerElement FutureDisposer where
  disposerElementKey (FutureDisposer key _) = key

  disposeEventually# self = do
    beginDispose# self <&> \case
      DisposeResultAwait future -> future
      DisposeResultDependencies deps -> flattenDisposeDependencies deps

  beginDispose# (FutureDisposer key var) = do
    fdeps <- mapFinalizeTOnce var \future -> do

      promise <- newPromise
      callOnceCompleted_ future \(RightAbsurdEx disposer) -> do
        fdeps <- beginDisposeDisposer disposer
        tryFulfillPromise_ promise fdeps

      pure (join (toFuture promise))

    pure (DisposeResultDependencies (DisposeDependencies key fdeps))

instance ToFuture '[] () FutureDisposer where
  toFuture (FutureDisposer _ var) = do
    deps <- join (toFuture var)
    mapM_ flattenDisposeDependencies deps

instance Disposable FutureDisposer where
  getDisposer x = mkDisposer [x]

futureDisposer :: Future '[] Disposer -> STMc NoRetry '[] Disposer
futureDisposer future = do
  peekFuture future >>= \case
    Just (RightAbsurdEx disposer) ->
      -- Simply pass through the disposer if the future is already completed or
      -- trivial.
      pure disposer
    Nothing -> do
      key <- newUniqueSTM
      var <- newTOnce future
      pure (getDisposer (FutureDisposer key var))

futureDisposerGeneric :: (Disposable a, MonadSTMc NoRetry '[] m) => Future '[] a -> m Disposer
futureDisposerGeneric x = liftSTMc (futureDisposer (getDisposer <$> x))
