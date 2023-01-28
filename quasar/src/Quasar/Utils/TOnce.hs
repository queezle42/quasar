module Quasar.Utils.TOnce (
  TOnce,
  newTOnce,
  newTOnceIO,
  mapFinalizeTOnce,
  finalizeTOnce,
  readTOnce,

  -- * Exceptions
  TOnceAlreadyFinalized,
) where

import Quasar.Future
import Quasar.Prelude

data TOnceAlreadyFinalized = TOnceAlreadyFinalized
  deriving stock (Eq, Show)
  deriving anyclass Exception

data TOnce a b = TOnce (TVar (Either a b))

instance IsFuture b (TOnce a b) where
  --toFuture (TOnce _ promise) = toFuture promise
  toFuture = undefined

newTOnce :: MonadSTMc NoRetry '[] m => a -> m (TOnce a b)
newTOnce initial = TOnce <$> newTVar (Left initial)

newTOnceIO :: MonadIO m => a -> m (TOnce a b)
newTOnceIO initial = TOnce <$> newTVarIO (Left initial)


--mapFinalizeTOnce :: MonadSTMc NoRetry '[] m => TOnce a (Future b) -> (a -> m b) -> m (Future b)
mapFinalizeTOnce :: MonadSTMc NoRetry '[] m => TOnce a b -> (a -> m b) -> m (Future b)
mapFinalizeTOnce = undefined
--mapFinalizeTOnce (TOnce var) fn = do
--  readTVar var >>= \case
--    Just initial -> do
--      writeTVar var Nothing
--      final <- fn initial
--      tryFulfillPromise_ promise final
--      pure (toFuture promise)
--    Nothing -> pure (toFuture promise)

finalizeTOnce :: MonadSTMc NoRetry '[TOnceAlreadyFinalized] m => TOnce a b -> b -> m ()
finalizeTOnce (TOnce var) value =
  readTVar var >>= \case
    Left _ -> writeTVar var (Right value)
    Right _ -> throwC TOnceAlreadyFinalized

readTOnce :: MonadSTMc NoRetry '[] m => TOnce a b -> m (Either a b)
readTOnce (TOnce var) = readTVar var
