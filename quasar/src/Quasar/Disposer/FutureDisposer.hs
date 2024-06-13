module Quasar.Disposer.FutureDisposer (
  futureDisposer,
  futureDisposerGeneric,
) where

import Quasar.Disposer.Core
import Quasar.Future
import Quasar.Prelude
import Quasar.Utils.TOnce

data FutureDisposer = FutureDisposer Unique (TOnce (Future '[] (Maybe Disposer)) (Future '[] [DisposeDependencies]))

instance IsDisposerElement FutureDisposer where
  disposerElementKey (FutureDisposer key _) = key

  disposeEventually# self = do
    beginDispose# self <&> \case
      DisposeResultAwait future -> future
      DisposeResultDependencies deps -> flattenDisposeDependencies deps

  beginDispose# (FutureDisposer key var) = do
    fdeps <- mapFinalizeTOnce var \future -> do

      promise <- newPromise
      callOnceCompleted_ future \case
        (RightAbsurdEx Nothing) -> do
          tryFulfillPromise_ promise (pure [])
        (RightAbsurdEx (Just disposer)) -> do
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

futureDisposer :: Future e Disposer -> STMc NoRetry '[] Disposer
futureDisposer future = do
  peekFuture future >>= \case
    Just (Left _) ->
      -- Return an empty disposer if the future has already failed
      pure mempty
    Just (Right disposer) ->
      -- Simply pass through the disposer if the future is already completed.
      pure disposer
    Nothing -> do
      key <- newUniqueSTM
      var <- newTOnce (rightToMaybe <$> tryAllC future)
      pure (getDisposer (FutureDisposer key var))

futureDisposerGeneric :: (Disposable a, MonadSTMc NoRetry '[] m) => Future e a -> m Disposer
futureDisposerGeneric x = liftSTMc (futureDisposer (getDisposer <$> x))
