module Qd.Observable.Delta where

import Qd.Observable
import Qd.Prelude

import Conduit
import qualified Data.HashMap.Strict as HM
import Data.Binary (Binary(..))

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
