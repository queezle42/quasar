module Quasar.Utils.Map (
  lookupDelete,
  insertCheckReplace,
) where

import Control.Monad.State.Lazy qualified as State
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Tuple (swap)
import Quasar.Prelude
import Quasar.Utils.ExtraT

-- | Lookup and delete a value from a Map in one operation
lookupDelete :: forall k v. Ord k => k -> Map k v -> (Maybe v, Map k v)
lookupDelete key m = swap $ State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (Map k v)
    fn = Map.alterF (\c -> State.put c >> pure Nothing) key m

-- | Insert or replace the given value. Returns `True` if a previous element was replaced.
insertCheckReplace :: forall k v. Ord k => k -> v -> Map k v -> (Bool, Map k v)
insertCheckReplace key value hm = runExtra $ Map.alterF fn key hm
  where
    fn :: Maybe v -> Extra Bool (Maybe v)
    fn Nothing = Extra (False, Just value)
    fn (Just _) = Extra (True, Just value)
