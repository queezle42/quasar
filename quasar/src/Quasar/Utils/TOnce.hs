module Quasar.Utils.TOnce (
  TOnce,
  newTOnce,
  newTOnceIO,
  mapFinalizeTOnce,
  finalizeTOnce,

  -- * Exceptions
  TOnceAlreadyFinalized,
) where

import Quasar.Future
import Quasar.Prelude

data TOnceAlreadyFinalized = TOnceAlreadyFinalized
  deriving stock (Eq, Show)
  deriving anyclass Exception

data TOnce a b = TOnce (TVar (Maybe a)) (Promise b)

instance IsFuture b (TOnce a b) where
  toFuture (TOnce _ promise) = toFuture promise

newTOnce :: MonadSTMc NoRetry '[] m => a -> m (TOnce a b)
newTOnce initial = TOnce <$> newTVar (Just initial) <*> newPromise

newTOnceIO :: MonadIO m => a -> m (TOnce a b)
newTOnceIO initial = TOnce <$> newTVarIO (Just initial) <*> newPromiseIO


mapFinalizeTOnce :: MonadSTMc NoRetry '[] m => TOnce a b -> (a -> m b) -> m (Future b)
mapFinalizeTOnce (TOnce var promise) fn = do
  readTVar var >>= \case
    Just initial -> do
      writeTVar var Nothing
      final <- fn initial
      tryFulfillPromise_ promise final
      pure (toFuture promise)
    Nothing -> pure (toFuture promise)

finalizeTOnce :: MonadSTMc NoRetry '[TOnceAlreadyFinalized] m => TOnce a b -> b -> m ()
finalizeTOnce (TOnce var promise) value =
  readTVar var >>= \case
    Just _ -> do
      writeTVar var Nothing
      tryFulfillPromise_ promise value
    Nothing -> throwC TOnceAlreadyFinalized
