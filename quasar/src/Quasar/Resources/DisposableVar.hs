module Quasar.Resources.DisposableVar (
  DisposableVar,
  newDisposableVar,
  tryReadDisposableVar,
) where

import Quasar.Future (ToFuture(..), IsFuture(..))
import Quasar.Prelude
import Quasar.Resources (IsDisposerElement(..), Disposable (getDisposer), toDisposer)
import Quasar.Utils.CallbackRegistry


data DisposableVarState a
  = DisposableVarAlive a (a -> STMc NoRetry '[] ()) (CallbackRegistry ())
  | DisposableVarDisposing (CallbackRegistry ())
  | DisposableVarDisposed

data DisposableVar a = DisposableVar Unique (TVar (DisposableVarState a))

instance IsDisposerElement (DisposableVar a) where
  disposerElementKey (DisposableVar key _) = key
  disposeEventually# (DisposableVar _ var) = do
    readTVar var >>= \case
      DisposableVarDisposed -> pure (pure ())
      DisposableVarDisposing _ -> pure (pure ())
      DisposableVarAlive content disposeFn callbackRegistry -> do
        writeTVar var (DisposableVarDisposing callbackRegistry)
        disposeFn content
        writeTVar var DisposableVarDisposed
        pure (pure ())

instance Disposable (DisposableVar a) where
  getDisposer x = toDisposer [x]


instance ToFuture () (DisposableVar a) where

instance IsFuture () (DisposableVar a) where
  readFuture# (DisposableVar _ var) = do
    readTVar var >>= \case
      DisposableVarDisposed -> pure ()
      _ -> retry
  readOrAttachToFuture# (DisposableVar _ var) callback = do
    readTVar var >>= \case
      DisposableVarDisposed -> pure (Right ())
      DisposableVarDisposing callbackRegistry -> Left <$> registerCallback callbackRegistry callback
      DisposableVarAlive _ _ callbackRegistry -> Left <$> registerCallback callbackRegistry callback

newDisposableVar :: MonadSTMc NoRetry '[] m => a -> (a -> STMc NoRetry '[] ()) -> m (DisposableVar a)
newDisposableVar content disposeFn = liftSTMc do
  key <- newUniqueSTM
  callbackRegistry <- newCallbackRegistry
  var <- newTVar (DisposableVarAlive content disposeFn callbackRegistry)
  pure $ DisposableVar key var

tryReadDisposableVar :: MonadSTMc NoRetry '[] m => DisposableVar a -> m (Maybe a)
tryReadDisposableVar (DisposableVar _ var) = do
  readTVar var >>= \case
    DisposableVarDisposed -> pure Nothing
    DisposableVarDisposing _ -> pure Nothing
    DisposableVarAlive content _ _ -> pure (Just content)
