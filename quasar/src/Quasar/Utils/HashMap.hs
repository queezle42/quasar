module Quasar.Utils.HashMap (
  lookupInsert,
  checkInsert,
  lookupDelete,
) where

import Control.Monad.State.Lazy as State
import Data.HashMap.Strict qualified as HM
import Data.Hashable qualified as Hashable
import Data.Tuple (swap)
import Quasar.Prelude
import Quasar.Utils.ExtraT

-- | Lookup and delete a value from a HashMap in one operation
lookupDelete :: forall k v. Hashable.Hashable k => k -> HM.HashMap k v -> (Maybe v, HM.HashMap k v)
lookupDelete key m = swap $ State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (HM.HashMap k v)
    fn = HM.alterF (\c -> State.put c >> pure Nothing) key m

-- | Lookup a value and insert the given value if it is not already a member of the HashMap.
lookupInsert :: forall k v. Hashable.Hashable k => k -> v -> HM.HashMap k v -> (v, HM.HashMap k v)
lookupInsert key value hm = runExtra $ HM.alterF fn key hm
  where
    fn :: Maybe v -> Extra v (Maybe v)
    fn Nothing = Extra (value, Just value)
    fn (Just oldValue) = Extra (oldValue, Just oldValue)

-- | Insert the given value if it is not already a member of the HashMap. Returns `True` if the element was inserted.
checkInsert :: forall k v. Hashable.Hashable k => k -> v -> HM.HashMap k v -> (Bool, HM.HashMap k v)
checkInsert key value hm = runExtra $ HM.alterF fn key hm
  where
    fn :: Maybe v -> Extra Bool (Maybe v)
    fn Nothing = Extra (True, Just value)
    fn (Just oldValue) = Extra (False, Just oldValue)
