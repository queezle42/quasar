module Quasar.Utils.TOnce (
  TOnce,
  newTOnce,
  newTOnceIO,
  finalizeTOnce,
  readTOnce,
  readTOnceIO,
  mapFinalizeTOnce,

  -- * Exceptions
  TOnceAlreadyFinalized,
) where

import Data.Bifunctor qualified as Bifunctor
import Quasar.Future
import Quasar.Prelude
import Quasar.Utils.CallbackRegistry

data TOnceAlreadyFinalized = TOnceAlreadyFinalized
  deriving stock (Eq, Show)

instance Exception TOnceAlreadyFinalized

newtype TOnce a b = TOnce (TVar (Either (a, CallbackRegistry b) b))

instance ToFuture b (TOnce a b)

instance IsFuture b (TOnce a b) where
  readFuture# (TOnce var) =
    readTVar var >>= \case
      Left _ -> retry
      Right value -> pure value

  readOrAttachToFuture# (TOnce var) callback = do
    readTVar var >>= \case
      Left (_, registry) -> Left <$> registerCallback registry callback
      Right value -> pure (Right value)

newTOnce :: MonadSTMc NoRetry '[] m => a -> m (TOnce a b)
newTOnce initial = liftSTMc do
  registry <- newCallbackRegistry
  TOnce <$> newTVar (Left (initial, registry))

newTOnceIO :: MonadIO m => a -> m (TOnce a b)
newTOnceIO initial = liftIO do
  registry <- newCallbackRegistryIO
  TOnce <$> newTVarIO (Left (initial, registry))

-- | Finalizes the `TOnce` by replacing the content, if not already finalized.
finalizeTOnce :: MonadSTMc NoRetry '[TOnceAlreadyFinalized] m => TOnce a b -> b -> m ()
finalizeTOnce (TOnce var) value = liftSTMc @NoRetry @'[TOnceAlreadyFinalized] do
  readTVar var >>= \case
    Left (_, registry) -> do
      writeTVar var (Right value)
      liftSTMc $ callCallbacks registry value
    Right _ -> throwC TOnceAlreadyFinalized

readTOnce :: MonadSTMc NoRetry '[] m => TOnce a b -> m (Either a b)
readTOnce (TOnce var) = Bifunctor.first fst <$> readTVar var

readTOnceIO :: MonadIO m => TOnce a b -> m (Either a b)
readTOnceIO (TOnce var) = Bifunctor.first fst <$> readTVarIO var

-- | Finalizes the `TOnce` by running an STM action.
--
-- Reentrant-safe.
mapFinalizeTOnce :: MonadSTMc NoRetry '[] m => TOnce a (Future b) -> (a -> m (Future b)) -> m (Future b)
mapFinalizeTOnce (TOnce var) fn = do
  readTVar var >>= \case
    Left (initial, registry) -> do
      promise <- newPromise
      let future = join (toFuture promise)
      writeTVar var (Right future)
      liftSTMc $ callCallbacks registry future
      final <- fn initial
      tryFulfillPromise_ promise final
      pure final
    Right future -> pure future
