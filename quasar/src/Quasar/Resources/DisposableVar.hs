module Quasar.Resources.DisposableVar (
  DisposableVar,
  newDisposableVar,
  newDisposableVarIO,
  tryReadDisposableVar,

  -- * `TDisposable` variant
  TDisposableVar,
  newTDisposableVar,
  newTDisposableVarIO,
  tryReadTDisposableVar,
) where

import Control.Monad.Catch
import Data.Hashable (Hashable(..))
import Quasar.Future (Future, ToFuture(..), IsFuture(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.TOnce
import Quasar.Exceptions (ExceptionSink, DisposeException (..))
import Quasar.Async.Fork (forkFutureSTM)



type DisposableVarState a = TOnce (ExceptionSink, a -> IO (), a) (Future ())

data DisposableVar a = DisposableVar Unique (DisposableVarState a)

instance ToFuture () (DisposableVar a) where
  toFuture (DisposableVar _ state) = join (toFuture state)

instance IsDisposerElement (DisposableVar a) where
  disposerElementKey (DisposableVar key _) = key
  disposeEventually# (DisposableVar _ disposeState) = do
    mapFinalizeTOnce disposeState \(sink, fn, value) ->
      void . toFuture <$> forkFutureSTM (wrapDisposeException (fn value)) sink

instance Disposable (DisposableVar a) where
  getDisposer x = mkDisposer [x]

instance Eq (DisposableVar a) where
  (DisposableVar x _) == (DisposableVar y _) = x == y

instance Hashable (DisposableVar a) where
  hash (DisposableVar key _) = hash key
  hashWithSalt salt (DisposableVar key _) = hashWithSalt salt key

wrapDisposeException :: MonadCatch m => m a -> m a
wrapDisposeException fn = fn `catchAll` \ex -> throwM (DisposeException ex)

tryReadDisposableVar :: MonadSTMc NoRetry '[] m => DisposableVar a -> m (Maybe a)
tryReadDisposableVar (DisposableVar _ stateTOnce) = liftSTMc @NoRetry @'[] do
  readTOnce stateTOnce <&> \case
    Left (_, _, value) -> Just value
    _ -> Nothing

newDisposableVar :: MonadSTMc NoRetry '[] m => ExceptionSink -> (a -> IO ()) -> a -> m (DisposableVar a)
newDisposableVar sink fn value = do
  key <- newUniqueSTM
  DisposableVar key <$> newTOnce (sink, fn, value)

newDisposableVarIO :: MonadIO m => ExceptionSink -> (a -> IO ()) -> a -> m (DisposableVar a)
newDisposableVarIO sink fn value = do
  key <- newUnique
  DisposableVar key <$> newTOnceIO (sink, fn, value)



data TDisposableVarState a
  = TDisposableVarAlive a (a -> STMc NoRetry '[] ()) (CallbackRegistry ())
  | TDisposableVarDisposing (CallbackRegistry ())
  | TDisposableVarDisposed

data TDisposableVar a = TDisposableVar Unique (TVar (TDisposableVarState a))

instance IsDisposerElement (TDisposableVar a) where
  disposerElementKey (TDisposableVar key _) = key
  disposeEventually# dvar =
    -- NOTE On reentrant call the future does not reflect not-yet disposed
    -- state.
    pure () <$ disposeTDisposerElement dvar

instance IsTDisposerElement (TDisposableVar a) where
  disposeTDisposerElement (TDisposableVar _ var) = do
    readTVar var >>= \case
      TDisposableVarDisposed -> pure ()
      TDisposableVarDisposing _ -> pure ()
      TDisposableVarAlive content disposeFn callbackRegistry -> do
        writeTVar var (TDisposableVarDisposing callbackRegistry)
        disposeFn content
        writeTVar var TDisposableVarDisposed
        callCallbacks callbackRegistry ()

instance Disposable (TDisposableVar a) where
  getDisposer x = mkDisposer [x]

instance TDisposable (TDisposableVar a) where
  getTDisposer x = mkTDisposer [x]


instance ToFuture () (TDisposableVar a) where

instance IsFuture () (TDisposableVar a) where
  readFuture# (TDisposableVar _ var) = do
    readTVar var >>= \case
      TDisposableVarDisposed -> pure ()
      _ -> retry
  readOrAttachToFuture# (TDisposableVar _ var) callback = do
    readTVar var >>= \case
      TDisposableVarDisposed -> pure (Right ())
      TDisposableVarDisposing callbackRegistry -> Left <$> registerCallback callbackRegistry callback
      TDisposableVarAlive _ _ callbackRegistry -> Left <$> registerCallback callbackRegistry callback


instance Eq (TDisposableVar a) where
  (TDisposableVar x _) == (TDisposableVar y _) = x == y

instance Hashable (TDisposableVar a) where
  hash (TDisposableVar key _) = hash key
  hashWithSalt salt (TDisposableVar key _) = hashWithSalt salt key

newTDisposableVar :: MonadSTMc NoRetry '[] m => a -> (a -> STMc NoRetry '[] ()) -> m (TDisposableVar a)
newTDisposableVar content disposeFn = liftSTMc do
  key <- newUniqueSTM
  callbackRegistry <- newCallbackRegistry
  var <- newTVar (TDisposableVarAlive content disposeFn callbackRegistry)
  pure $ TDisposableVar key var

newTDisposableVarIO :: MonadIO m => a -> (a -> STMc NoRetry '[] ()) -> m (TDisposableVar a)
newTDisposableVarIO content disposeFn = liftIO do
  key <- newUnique
  callbackRegistry <- newCallbackRegistryIO
  var <- newTVarIO (TDisposableVarAlive content disposeFn callbackRegistry)
  pure $ TDisposableVar key var

tryReadTDisposableVar :: MonadSTMc NoRetry '[] m => TDisposableVar a -> m (Maybe a)
tryReadTDisposableVar (TDisposableVar _ var) = do
  readTVar var >>= \case
    TDisposableVarDisposed -> pure Nothing
    TDisposableVarDisposing _ -> pure Nothing
    TDisposableVarAlive content _ _ -> pure (Just content)
