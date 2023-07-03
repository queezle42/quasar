module Quasar.Observable.List (
  ObservableList(..),
  ToObservableList(..),
  ObservableListDelta(..),
  ObservableListOperation(..),
) where

import Quasar.Prelude
import Quasar.Observable.Core


class ToObservableList canLoad exceptions v a where
  toObservableList :: a -> ObservableList canLoad exceptions v

data ObservableList canLoad exceptions v
  = forall a. IsObservableList canLoad exceptions v a => ObservableList a

instance ToObservableList canLoad exceptions v (ObservableList canLoad exceptions v) where
  toObservableList = id

instance IsObservableCore canLoad exceptions [] v (ObservableList canLoad exceptions v) where
  readObservable# (ObservableList x) = readObservable# x
  attachObserver# (ObservableList x) = attachObserver# x
  attachEvaluatedObserver# (ObservableList x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableList x) = isCachedObservable# x

instance IsObservableList canLoad exceptions v (ObservableList canLoad exceptions v) where
  member# (ObservableList x) = member# x
  lookupValue# (ObservableList x) = lookupValue# x


class IsObservableCore canLoad exceptions [] v a => IsObservableList canLoad exceptions v a where
  member# :: Ord v => a -> v -> Observable canLoad exceptions Bool
  member# = undefined

  lookupValue# :: Ord v => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  lookupValue# x selector = undefined

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableList canLoad exceptions v
  query# = undefined


instance IsObservableList canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions []) v) where
