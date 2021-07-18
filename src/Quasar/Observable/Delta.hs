module Quasar.Observable.Delta (
  IsDeltaObservable(..),
  Delta(..),
  DeltaObservable,
) where

import Data.Binary (Binary)
import Data.Binary qualified as B
import Data.HashMap.Strict qualified as HM
import Quasar.Core
import Quasar.Observable
import Quasar.Prelude

data Delta k v = Reset (HM.HashMap k v) | Insert k v | Delete k
  deriving stock (Eq, Show, Generic)
instance Functor (Delta k) where
  fmap f (Reset state) = Reset (f <$> state)
  fmap f (Insert key value) = Insert key (f value)
  fmap _ (Delete key) = Delete key
instance (Eq k, Hashable k, Binary k, Binary v) => Binary (Delta k v) where
  get = do
    (tag :: Word8) <- B.get
    case tag of
      0 -> Reset . HM.fromList <$> B.get
      1 -> Insert <$> B.get <*> B.get
      2 -> Delete <$> B.get
      _ -> fail "Invalid tag"
  put (Reset hashmap) = B.put (0 :: Word8) >> B.put (HM.toList hashmap)
  put (Insert key value) = B.put (1 :: Word8) >> B.put key >> B.put value
  put (Delete key) = B.put (2 :: Word8) >> B.put key

class IsObservable (HM.HashMap k v) o => IsDeltaObservable k v o | o -> k, o -> v where
  subscribeDelta :: o -> (Delta k v -> IO ()) -> IO Disposable

--observeHashMapDefaultImpl :: forall k v o. (Eq k, Hashable k) => IsDeltaObservable k v o => o -> (HM.HashMap k v -> IO ()) -> IO Disposable
--observeHashMapDefaultImpl o callback = do
--  hashMapRef <- newIORef HM.empty
--  subscribeDelta o (deltaCallback hashMapRef)
--  where
--    deltaCallback :: IORef (HM.HashMap k v) -> Delta k v -> IO ()
--    deltaCallback hashMapRef delta = callback =<< atomicModifyIORef' hashMapRef ((\x -> (x, x)) . applyDelta delta)
--    applyDelta :: Delta k v -> HM.HashMap k v -> HM.HashMap k v
--    applyDelta (Reset state) = const state
--    applyDelta (Insert key value) = HM.insert key value
--    applyDelta (Delete key) = HM.delete key


data DeltaObservable k v = forall o. IsDeltaObservable k v o => DeltaObservable o
instance IsRetrievable (HM.HashMap k v) (DeltaObservable k v) where
  retrieve (DeltaObservable o) = retrieve o
instance IsObservable (HM.HashMap k v) (DeltaObservable k v) where
  subscribe (DeltaObservable o) = subscribe o
instance IsDeltaObservable k v (DeltaObservable k v) where
  subscribeDelta (DeltaObservable o) = subscribeDelta o
instance Functor (DeltaObservable k) where
  fmap f (DeltaObservable o) = DeltaObservable $ MappedDeltaObservable f o


data MappedDeltaObservable k b = forall a o. IsDeltaObservable k a o => MappedDeltaObservable (a -> b) o
instance IsRetrievable (HM.HashMap k b) (MappedDeltaObservable k b) where
  retrieve (MappedDeltaObservable f o) = f <<$>> retrieve o
instance IsObservable (HM.HashMap k b) (MappedDeltaObservable k b) where
  subscribe (MappedDeltaObservable f o) callback = subscribe o (callback . fmap (fmap f))
instance IsDeltaObservable k b (MappedDeltaObservable k b) where
  subscribeDelta (MappedDeltaObservable f o) callback = subscribeDelta o (callback . fmap f)
