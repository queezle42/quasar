module Quasar.Utils.TOnce (
  TOnce,
  newTOnce,
  newTOnceIO,
  mapFinalizeTOnce,
  finalizeTOnce,
  readTOnceState,
  readTOnceResult,
) where

import Quasar.Future
import Quasar.Prelude

data TOnceAlreadyFinalized = TOnceAlreadyFinalized
  deriving stock (Eq, Show)
  deriving anyclass Exception

newtype TOnce a b = TOnce (TVar (Either a b))

instance IsFuture b (TOnce a b) where
  toFuture = unsafeAwaitSTM . readTOnceResult

newTOnce :: MonadSTM' r t m => a -> m (TOnce a b)
newTOnce initial = TOnce <$> newTVar (Left initial)

newTOnceIO :: MonadIO m => a -> m (TOnce a b)
newTOnceIO initial = TOnce <$> newTVarIO (Left initial)


mapFinalizeTOnce :: MonadSTM' r t m => TOnce a b -> (a -> m b) -> m b
mapFinalizeTOnce (TOnce var) fn =
  readTVar var >>= \case
    Left initial -> do
      final <- fn initial
      writeTVar var (Right final)
      pure final
    Right final -> pure final

finalizeTOnce :: MonadSTM' r CanThrow m => TOnce a b -> b -> m ()
finalizeTOnce (TOnce var) value =
  readTVar var >>= \case
    Left _ -> writeTVar var (Right value)
    Right _ -> throwSTM TOnceAlreadyFinalized


readTOnceState :: MonadSTM' r t m => TOnce a b -> m (Either a b)
readTOnceState (TOnce var) = readTVar var

readTOnceResult :: MonadSTM' CanRetry t m => TOnce a b -> m b
readTOnceResult switch =
  readTOnceState switch >>= \case
    Right final -> pure final
    _ -> retry
