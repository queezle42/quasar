{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Finalizer (
  Finalizers(..),
  newFinalizers,
  registerFinalizer,
  runFinalizers,
) where

import Quasar.Prelude

newtype Finalizers = Finalizers (TVar (Maybe [STMc NoRetry '[] ()]))

newFinalizers :: MonadSTMc NoRetry '[] m => m Finalizers
newFinalizers = Finalizers <$> newTVar (Just [])

registerFinalizer :: MonadSTMc NoRetry '[] m => Finalizers -> STMc NoRetry '[] () -> m Bool
registerFinalizer (Finalizers finalizerVar) finalizer =
  readTVar finalizerVar >>= \case
    Just finalizers -> do
      writeTVar finalizerVar (Just (finalizer : finalizers))
      pure True
    Nothing -> pure False

runFinalizers :: Finalizers -> STMc NoRetry '[] ()
runFinalizers (Finalizers finalizerVar) = do
  readTVar finalizerVar >>= \case
    Just finalizers -> do
      liftSTMc $ sequence_ finalizers
      writeTVar finalizerVar Nothing
    Nothing -> traceM "runFinalizers was called multiple times (it must only be run once)"
