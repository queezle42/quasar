module Qd.Observable.Delta where

import Qd.Observable
import Qd.Prelude

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

class Observable (HM.HashMap k v) o => DeltaObservable k v o | o -> k, o -> v where
  subscribeDelta :: o -> (Delta k v -> IO ()) -> IO SubscriptionHandle
  --subscribeDeltaC :: o -> ConduitT () (Delta k v) IO ()
  --subscribeDeltaC = undefined
  --{-# MINIMAL subscribeDelta | subscribeDeltaC #-}

observeHashMapDefaultImpl :: forall k v o. (Eq k, Hashable k) => DeltaObservable k v o => o -> (HM.HashMap k v -> IO ()) -> IO SubscriptionHandle
observeHashMapDefaultImpl o callback = do
  hashMapRef <- newIORef HM.empty
  subscribeDelta o (deltaCallback hashMapRef)
  where
    deltaCallback :: IORef (HM.HashMap k v) -> Delta k v -> IO ()
    deltaCallback hashMapRef delta = callback =<< atomicModifyIORef' hashMapRef (dup . (applyDelta delta))
    applyDelta :: Delta k v -> HM.HashMap k v -> HM.HashMap k v
    applyDelta (Reset state) = const state
    applyDelta (Insert key value) = HM.insert key value
    applyDelta (Delete key) = HM.delete key


data SomeDeltaObservable k v = forall o. DeltaObservable k v o => SomeDeltaObservable o
instance Gettable (HM.HashMap k v) (SomeDeltaObservable k v) where
  getValue (SomeDeltaObservable o) = getValue o
instance Observable (HM.HashMap k v) (SomeDeltaObservable k v) where
  subscribe (SomeDeltaObservable o) = subscribe o
instance DeltaObservable k v (SomeDeltaObservable k v) where
  subscribeDelta (SomeDeltaObservable o) = subscribeDelta o
instance Functor (SomeDeltaObservable k) where
  fmap f (SomeDeltaObservable o) = SomeDeltaObservable $ MappedDeltaObservable f o


data MappedDeltaObservable k b = forall a o. DeltaObservable k a o => MappedDeltaObservable (a -> b) o
instance Gettable (HM.HashMap k b) (MappedDeltaObservable k b) where
  getValue (MappedDeltaObservable f o) = f <$$> getValue o
instance Observable (HM.HashMap k b) (MappedDeltaObservable k b) where
  subscribe (MappedDeltaObservable f o) callback = subscribe o (callback . fmap (fmap f))
instance DeltaObservable k b (MappedDeltaObservable k b) where
  subscribeDelta (MappedDeltaObservable f o) callback = subscribeDelta o (callback . fmap f)
