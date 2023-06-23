module Quasar.Observable.Set (
  ObservableSet,
  ToObservableSet,
  toObservableSet,
  ObservableSetDelta(..),
  ObservableSetOperation(..),
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Quasar.Observable.Core
import Quasar.Prelude

class ToObservableSet canLoad exceptions v a where
  toObservableSet :: a -> ObservableSet canLoad exceptions v

data ObservableSet canLoad exceptions v
  = forall a. IsObservableSet canLoad exceptions v a => ObservableSet a

instance ToObservableSet canLoad exceptions v (ObservableSet canLoad exceptions v) where
  toObservableSet = id

instance IsObservableCore canLoad exceptions Set v (ObservableSet canLoad exceptions v) where
  readObservable# (ObservableSet x) = readObservable# x
  attachObserver# (ObservableSet x) = attachObserver# x
  attachEvaluatedObserver# (ObservableSet x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableSet x) = isCachedObservable# x

instance IsObservableSet canLoad exceptions v (ObservableSet canLoad exceptions v) where
  member# (ObservableSet x) = member# x
  lookupValue# (ObservableSet x) = lookupValue# x


class IsObservableCore canLoad exceptions Set v a => IsObservableSet canLoad exceptions v a where
  member# :: Ord v => a -> v -> ObservableI canLoad exceptions Bool
  member# = undefined

  lookupValue# :: Ord v => a -> Selector k -> ObservableI canLoad exceptions (Maybe v)
  lookupValue# x selector = undefined

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableSet canLoad exceptions v
  query# = undefined


instance IsObservableSet canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions Set) v) where
