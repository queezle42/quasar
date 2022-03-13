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

newTOnce :: a -> STM (TOnce a b)
newTOnce initial = TOnce <$> newTVar (Left initial)

newTOnceIO :: a -> IO (TOnce a b)
newTOnceIO initial = TOnce <$> newTVarIO (Left initial)


mapFinalizeTOnce :: TOnce a b -> (a -> STM b) -> STM b
mapFinalizeTOnce (TOnce var) fn =
  readTVar var >>= \case
    Left initial -> do
      final <- fn initial
      writeTVar var (Right final)
      pure final
    Right final -> pure final

finalizeTOnce :: TOnce a b -> b -> STM ()
finalizeTOnce (TOnce var) value =
  readTVar var >>= \case
    Left _ -> writeTVar var (Right value)
    Right _ -> throwSTM TOnceAlreadyFinalized


readTOnceState :: TOnce a b -> STM (Either a b)
readTOnceState (TOnce var) = readTVar var

readTOnceResult :: TOnce a b -> STM b
readTOnceResult switch =
  readTOnceState switch >>= \case
    Right final -> pure final
    _ -> retry
