module Qd.Observable.Delta where

import Qd.Observable
import Qd.Prelude

import Conduit
import qualified Data.HashMap.Strict as HM
import Data.Binary (Binary(..))
import Data.IORef

data Delta k v = Reset (HM.HashMap k v) | Add k v | Change k v | Remove k
  deriving (Eq, Show, Generic)
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
