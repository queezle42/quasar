module Qd.Observable.Delta where

import Qd.Observable
import Qd.Prelude

import Conduit
import qualified Data.HashMap.Strict as HM
import Data.Binary (Binary(..))
import Data.IORef

data Delta k v = Reset (HM.HashMap k v) | Add k v | Change k v | Remove k
  deriving (Eq, Show, Generic)
instance Functor (Delta k) where
  fmap f (Reset state) = Reset (f <$> state)
  fmap f (Add key value) = Add key (f value)
  fmap f (Change key value) = Add key (f value)
  fmap _ (Remove key) = Remove key
instance (Binary k, Binary v) => Binary (Delta k v) where
  get = undefined
  put = undefined

class Observable (HM.HashMap k v) o => DeltaObservable k v o | o -> k, o -> v where
  subscribeDelta :: o -> (Delta k v -> IO ()) -> IO SubscriptionHandle
  subscribeDelta = undefined
  subscribeDeltaC :: o -> ConduitT () (Delta k v) IO ()
  subscribeDeltaC = undefined
  {-# MINIMAL subscribeDelta | subscribeDeltaC #-}

observeHashMapDefaultImpl :: forall k v o. (Eq k, Hashable k) => DeltaObservable k v o => o -> (HM.HashMap k v -> IO ()) -> IO SubscriptionHandle
observeHashMapDefaultImpl o callback = do
  hashMapRef <- newIORef HM.empty
  subscribeDelta o (deltaCallback hashMapRef)
  where
    deltaCallback :: IORef (HM.HashMap k v) -> Delta k v -> IO ()
    deltaCallback hashMapRef delta = callback =<< atomicModifyIORef' hashMapRef ((\x->(x,x)) . (applyDelta delta))
    applyDelta :: Delta k v -> HM.HashMap k v -> HM.HashMap k v
    applyDelta (Reset state) = const state
    applyDelta (Add key value) = HM.insert key value
    applyDelta (Change key value) = HM.insert key value
    applyDelta (Remove key) = HM.delete key


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
