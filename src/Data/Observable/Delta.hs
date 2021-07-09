module Data.Observable.Delta where

import Data.Observable
import Quasar.Prelude

--import Conduit
import qualified Data.HashMap.Strict as HM
import Data.Binary (Binary(..))
import Data.IORef
import Data.Word (Word8)

data Delta k v = Reset (HM.HashMap k v) | Insert k v | Delete k
  deriving (Eq, Show, Generic)
instance Functor (Delta k) where
  fmap f (Reset state) = Reset (f <$> state)
  fmap f (Insert key value) = Insert key (f value)
  fmap _ (Delete key) = Delete key
instance (Eq k, Hashable k, Binary k, Binary v) => Binary (Delta k v) where
  get = do
    (tag :: Word8) <- get
    case tag of
      0 -> Reset . HM.fromList <$> get
      1 -> Insert <$> get <*> get
      2 -> Delete <$> get
      _ -> fail "Invalid tag"
  put (Reset hashmap) = put (0 :: Word8) >> put (HM.toList hashmap)
  put (Insert key value) = put (1 :: Word8) >> put key >> put value
  put (Delete key) = put (2 :: Word8) >> put key

class IsObservable (HM.HashMap k v) o => IsDeltaObservable k v o | o -> k, o -> v where
  subscribeDelta :: o -> (Delta k v -> IO ()) -> IO Disposable
  --subscribeDeltaC :: o -> ConduitT () (Delta k v) IO ()
  --subscribeDeltaC = undefined
  --{-# MINIMAL subscribeDelta | subscribeDeltaC #-}

observeHashMapDefaultImpl :: forall k v o. (Eq k, Hashable k) => IsDeltaObservable k v o => o -> (HM.HashMap k v -> IO ()) -> IO Disposable
observeHashMapDefaultImpl o callback = do
  hashMapRef <- newIORef HM.empty
  subscribeDelta o (deltaCallback hashMapRef)
  where
    deltaCallback :: IORef (HM.HashMap k v) -> Delta k v -> IO ()
    deltaCallback hashMapRef delta = callback =<< atomicModifyIORef' hashMapRef ((\x -> (x, x)) . (applyDelta delta))
    applyDelta :: Delta k v -> HM.HashMap k v -> HM.HashMap k v
    applyDelta (Reset state) = const state
    applyDelta (Insert key value) = HM.insert key value
    applyDelta (Delete key) = HM.delete key


data DeltaObservable k v = forall o. IsDeltaObservable k v o => DeltaObservable o
instance IsGettable (HM.HashMap k v) (DeltaObservable k v) where
  getValue (DeltaObservable o) = getValue o
instance IsObservable (HM.HashMap k v) (DeltaObservable k v) where
  subscribe (DeltaObservable o) = subscribe o
instance IsDeltaObservable k v (DeltaObservable k v) where
  subscribeDelta (DeltaObservable o) = subscribeDelta o
instance Functor (DeltaObservable k) where
  fmap f (DeltaObservable o) = DeltaObservable $ MappedDeltaObservable f o


data MappedDeltaObservable k b = forall a o. IsDeltaObservable k a o => MappedDeltaObservable (a -> b) o
instance IsGettable (HM.HashMap k b) (MappedDeltaObservable k b) where
  getValue (MappedDeltaObservable f o) = fmap f <$> getValue o
instance IsObservable (HM.HashMap k b) (MappedDeltaObservable k b) where
  subscribe (MappedDeltaObservable f o) callback = subscribe o (callback . fmap (fmap f))
instance IsDeltaObservable k b (MappedDeltaObservable k b) where
  subscribeDelta (MappedDeltaObservable f o) callback = subscribeDelta o (callback . fmap f)
