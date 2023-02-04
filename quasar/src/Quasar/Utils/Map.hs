module Quasar.Utils.Map (
  lookupDelete,
) where

import Control.Monad.State.Lazy qualified as State
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Tuple (swap)
import Quasar.Prelude

-- | Lookup and delete a value from a Map in one operation
lookupDelete :: forall k v. Ord k => k -> Map k v -> (Maybe v, Map k v)
lookupDelete key m = swap $ State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (Map k v)
    fn = Map.alterF (\c -> State.put c >> pure Nothing) key m
