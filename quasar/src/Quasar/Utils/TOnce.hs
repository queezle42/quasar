module Quasar.Utils.TOnce (
  TOnce,
  newTOnce,
  newTOnceIO,
  mapFinalizeTOnce,
  finalizeTOnce,
  readTOnceState,
  readTOnceResult,

  -- * Exceptions
  TOnceAlreadyFinalized,
) where

import Quasar.Future
import Quasar.Prelude

data TOnceAlreadyFinalized = TOnceAlreadyFinalized
  deriving stock (Eq, Show)
  deriving anyclass Exception

newtype TOnce a b = TOnce (TVar (Either a b))

instance IsFuture b (TOnce a b) where
  toFuture = unsafeAwaitSTMc . readTOnceResult

newTOnce :: MonadSTMc '[] m => a -> m (TOnce a b)
newTOnce initial = TOnce <$> newTVar (Left initial)

newTOnceIO :: MonadIO m => a -> m (TOnce a b)
newTOnceIO initial = TOnce <$> newTVarIO (Left initial)


-- TODO guard against reentry
mapFinalizeTOnce :: MonadSTMc '[] m => TOnce a b -> (a -> m b) -> m b
mapFinalizeTOnce (TOnce var) fn =
  readTVar var >>= \case
    Left initial -> do
      final <- fn initial
      writeTVar var (Right final)
      pure final
    Right final -> pure final

finalizeTOnce :: MonadSTMc '[Throw TOnceAlreadyFinalized] m => TOnce a b -> b -> m ()
finalizeTOnce (TOnce var) value =
  readTVar var >>= \case
    Left _ -> writeTVar var (Right value)
    Right _ -> throwC TOnceAlreadyFinalized


readTOnceState :: MonadSTMc '[] m => TOnce a b -> m (Either a b)
readTOnceState (TOnce var) = readTVar var

readTOnceResult :: MonadSTMc '[Retry] m => TOnce a b -> m b
readTOnceResult switch =
  readTOnceState switch >>= \case
    Right final -> pure final
    _ -> retry
