module Quasar.Resources.DisposableVar (
  DisposableVar,
  newDisposableVar,
  newDisposableVarIO,
  newFnDisposableVar,
  newFnDisposableVarIO,
  newSpecialDisposableVar,
  newSpecialDisposableVarIO,
  tryReadDisposableVar,
  tryReadDisposableVarIO,
  tryWriteDisposableVar,
  tryModifyDisposableVar,

  -- * `TDisposable` variant
  TDisposableVar,
  newTDisposableVar,
  newTDisposableVarIO,
  tryReadTDisposableVar,
  tryWriteTDisposableVar,
  tryModifyTDisposableVar,
) where

import Data.Bifunctor qualified as Bifunctor
import Data.Hashable (Hashable(..))
import Quasar.Exceptions (ExceptionSink)
import Quasar.Future (Future, ToFuture(..), IsFuture(..))
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.TOnce


data DisposableVar a = DisposableVar Unique (TOnce (a -> STMc NoRetry '[] Disposer, a) (Future [DisposeDependencies]))

instance ToFuture () (DisposableVar a) where
  toFuture (DisposableVar _ state) = do
    deps <- join (toFuture state)
    mapM_ flattenDisposeDependencies deps

instance IsDisposerElement (DisposableVar a) where
  disposerElementKey (DisposableVar key _) = key

  beginDispose# (DisposableVar key disposeState) = do
    fdeps <- mapFinalizeTOnce disposeState \(fn, value) ->
      beginDisposeDisposer =<< fn value
    pure (DisposeResultDependencies (DisposeDependencies key fdeps))

  disposeEventually# self = do
    beginDispose# self <&> \case
      DisposeResultAwait future -> future
      DisposeResultDependencies deps -> flattenDisposeDependencies deps

instance Disposable (DisposableVar a) where
  getDisposer x = mkDisposer [x]

instance Eq (DisposableVar a) where
  (DisposableVar x _) == (DisposableVar y _) = x == y

instance Hashable (DisposableVar a) where
  hash (DisposableVar key _) = hash key
  hashWithSalt salt (DisposableVar key _) = hashWithSalt salt key

tryReadDisposableVar :: MonadSTMc NoRetry '[] m => DisposableVar a -> m (Maybe a)
tryReadDisposableVar (DisposableVar _ stateTOnce) = liftSTMc @NoRetry @'[] do
  readTOnce stateTOnce <&> \case
    Left (_, value) -> Just value
    _ -> Nothing

tryReadDisposableVarIO :: MonadIO m => DisposableVar a -> m (Maybe a)
tryReadDisposableVarIO (DisposableVar _ stateTOnce) = liftIO do
  readTOnceIO stateTOnce <&> \case
    Left (_, value) -> Just value
    _ -> Nothing

-- | Try to write a `DisposableVar`. On success the previous content is
-- returned.
--
-- If the var is already disposed or currently disposing, `Nothing` is returned.
tryWriteDisposableVar :: MonadSTMc NoRetry '[] m => DisposableVar a -> a -> m (Maybe a)
tryWriteDisposableVar (DisposableVar _ var) newContent =
  snd <<$>> tryModifyTOnce var (Bifunctor.second \_ -> newContent)

-- | Try to modify a `DisposableVar`. On success the previous content is
-- returned.
--
-- If the var is already disposed or currently disposing, `Nothing` is returned.
tryModifyDisposableVar :: MonadSTMc NoRetry '[] m => DisposableVar a -> (a -> a) -> m (Maybe a)
tryModifyDisposableVar (DisposableVar _ var) fn =
  snd <<$>> tryModifyTOnce var (Bifunctor.second fn)


-- | Create a new `DisposableVar` that runs an `IO` function when it is
-- disposed.
newFnDisposableVar ::
  MonadSTMc NoRetry '[] m =>
  ExceptionSink ->
  (a -> IO ()) ->
  a ->
  m (DisposableVar a)
newFnDisposableVar sink fn = liftSTMc @NoRetry @'[] .
  newSpecialDisposableVar \value -> do
    newUnmanagedIODisposer (fn value) sink

-- | Create a new `DisposableVar` that disposes the current content using the
-- `Disposable` instance when the var is disposed.
newDisposableVar ::
  (Disposable a, MonadSTMc NoRetry '[] m) =>
  a ->
  m (DisposableVar a)
newDisposableVar value = do
  key <- newUniqueSTM
  DisposableVar key <$> newTOnce (pure . getDisposer, value)

-- | Create a new `DisposableVar` that calls a function when it is disposed.
-- The function selects a disposer, which is then disposed.
newSpecialDisposableVar ::
  MonadSTMc NoRetry '[] m =>
  (a -> STMc NoRetry '[] Disposer) ->
  a ->
  m (DisposableVar a)
newSpecialDisposableVar fn value = do
  key <- newUniqueSTM
  DisposableVar key <$> newTOnce (fn, value)

newFnDisposableVarIO ::
  MonadIO m =>
  ExceptionSink ->
  (a -> IO ()) ->
  a ->
  m (DisposableVar a)
newFnDisposableVarIO sink fn = liftIO .
  newSpecialDisposableVarIO \value -> do
    newUnmanagedIODisposer (fn value) sink

newDisposableVarIO ::
  (Disposable a, MonadIO m) =>
  a ->
  m (DisposableVar a)
newDisposableVarIO value = liftIO do
  key <- newUnique
  DisposableVar key <$> newTOnceIO (pure . getDisposer, value)

newSpecialDisposableVarIO ::
  MonadIO m =>
  (a -> STMc NoRetry '[] Disposer) ->
  a ->
  m (DisposableVar a)
newSpecialDisposableVarIO fn value = liftIO do
  key <- newUnique
  DisposableVar key <$> newTOnceIO (fn, value)



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

-- | Try to write a `TDisposableVar`. On success the previous content is
-- returned.
--
-- If the var is already disposed or currently disposing, `Nothing` is returned.
tryWriteTDisposableVar :: MonadSTMc NoRetry '[] m => TDisposableVar a -> a -> m (Maybe a)
tryWriteTDisposableVar (TDisposableVar _ var) newContent = do
  readTVar var >>= \case
    TDisposableVarDisposed -> pure Nothing
    TDisposableVarDisposing _ -> pure Nothing
    TDisposableVarAlive oldContent disposeFn callbackRegistry -> do
      writeTVar var (TDisposableVarAlive newContent disposeFn callbackRegistry)
      pure (Just oldContent)

-- | Try to modify a `TDisposableVar`. On success the previous content is
-- returned.
--
-- If the var is already disposed or currently disposing, `Nothing` is returned.
tryModifyTDisposableVar :: MonadSTMc NoRetry '[] m => TDisposableVar a -> (a -> a) -> m (Maybe a)
tryModifyTDisposableVar (TDisposableVar _ var) fn = do
  readTVar var >>= \case
    TDisposableVarDisposed -> pure Nothing
    TDisposableVarDisposing _ -> pure Nothing
    TDisposableVarAlive oldContent disposeFn callbackRegistry -> do
      writeTVar var (TDisposableVarAlive (fn oldContent) disposeFn callbackRegistry)
      pure (Just oldContent)
