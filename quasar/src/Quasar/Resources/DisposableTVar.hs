module Quasar.Resources.DisposableTVar (
  DisposableTVar,
  newDisposableTVar,
  tryReadDisposableTVar,
) where

import Quasar.Future (ToFuture(..), IsFuture(..))
import Quasar.Prelude
import Quasar.Resources (IsDisposerElement(..), Disposable (getDisposer), toDisposer)
import Quasar.Utils.CallbackRegistry


data DisposableTVarState a
  = DisposableTVarAlive a (a -> STMc NoRetry '[] ()) (CallbackRegistry ())
  | DisposableTVarDisposing (CallbackRegistry ())
  | DisposableTVarDisposed

data DisposableTVar a = DisposableTVar Unique (TVar (DisposableTVarState a))

instance IsDisposerElement (DisposableTVar a) where
  disposerElementKey (DisposableTVar key _) = key
  disposeEventually# (DisposableTVar _ var) = do
    readTVar var >>= \case
      DisposableTVarDisposed -> pure (pure ())
      DisposableTVarDisposing _ -> pure (pure ())
      DisposableTVarAlive content disposeFn callbackRegistry -> do
        writeTVar var (DisposableTVarDisposing callbackRegistry)
        disposeFn content
        writeTVar var DisposableTVarDisposed
        pure (pure ())

instance Disposable (DisposableTVar a) where
  getDisposer x = toDisposer [x]


instance ToFuture () (DisposableTVar a) where

instance IsFuture () (DisposableTVar a) where
  readFuture# (DisposableTVar _ var) = do
    readTVar var >>= \case
      DisposableTVarDisposed -> pure ()
      _ -> retry
  readOrAttachToFuture# (DisposableTVar _ var) callback = do
    readTVar var >>= \case
      DisposableTVarDisposed -> pure (Right ())
      DisposableTVarDisposing callbackRegistry -> Left <$> registerCallback callbackRegistry callback
      DisposableTVarAlive _ _ callbackRegistry -> Left <$> registerCallback callbackRegistry callback

newDisposableTVar :: MonadSTMc NoRetry '[] m => a -> (a -> STMc NoRetry '[] ()) -> m (DisposableTVar a)
newDisposableTVar content disposeFn = liftSTMc do
  key <- newUniqueSTM
  callbackRegistry <- newCallbackRegistry
  var <- newTVar (DisposableTVarAlive content disposeFn callbackRegistry)
  pure $ DisposableTVar key var

tryReadDisposableTVar :: MonadSTMc NoRetry '[] m => DisposableTVar a -> m (Maybe a)
tryReadDisposableTVar (DisposableTVar _ var) = do
  readTVar var >>= \case
    DisposableTVarDisposed -> pure Nothing
    DisposableTVarDisposing _ -> pure Nothing
    DisposableTVarAlive content _ _ -> pure (Just content)
