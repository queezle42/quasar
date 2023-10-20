{-# OPTIONS_GHC -Wno-orphans #-}

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
import Quasar.Observable.List
import Quasar.Prelude


newtype ObservableSetDelta v
  = ObservableSetDelta (Set (ObservableSetOperation v))

data ObservableSetOperation v = ObservableSetInsert v | ObservableSetDelete v
  deriving (Eq, Ord)

applyObservableSetOperation :: Ord v => ObservableSetOperation v -> Set v -> Set v
applyObservableSetOperation (ObservableSetInsert x) = Set.insert x
applyObservableSetOperation (ObservableSetDelete x) = Set.delete x

applyObservableSetOperations :: Ord v => Set (ObservableSetOperation v) -> Set v -> Set v
applyObservableSetOperations ops old = Set.foldr applyObservableSetOperation old ops

instance Ord v => ObservableContainer Set v where
  type ContainerConstraint _canLoad _exceptions Set v _a = ()
  type Delta Set = ObservableSetDelta
  applyDelta (ObservableSetDelta ops) old = Just (applyObservableSetOperations ops old)
  mergeDelta (ObservableSetDelta old) (ObservableSetDelta new) = ObservableSetDelta (Set.union new old)

instance ContainerCount Set where
  containerCount# x = fromIntegral (Set.size x)
  containerIsEmpty# x = Set.null x


type ToObservableSet canLoad exceptions v = ToObservableT canLoad exceptions Set v

toObservableSet :: ToObservableSet canLoad exceptions v a => a -> ObservableSet canLoad exceptions v
toObservableSet x = ObservableSet (toObservableT x)

newtype ObservableSet canLoad exceptions v = ObservableSet (ObservableT canLoad exceptions Set v)

instance ToObservableT canLoad exceptions Set v (ObservableSet canLoad exceptions v) where
  toObservableT (ObservableSet x) = x

instance Ord v => IsObservableCore canLoad exceptions Set v (ObservableSet canLoad exceptions v) where
  readObservable# (ObservableSet x) = readObservable# x
  attachObserver# (ObservableSet x) = attachObserver# x
  attachEvaluatedObserver# (ObservableSet x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableSet x) = isCachedObservable# x

instance Ord v => IsObservableSet canLoad exceptions v (ObservableSet canLoad exceptions v) where
  --member# (ObservableSet x) = member# x
  --lookupValue# (ObservableSet x) = lookupValue# x


class IsObservableCore canLoad exceptions Set v a => IsObservableSet canLoad exceptions v a where
  --member# :: Ord v => a -> v -> Observable canLoad exceptions Bool
  --member# = undefined

  --lookupValue# :: Ord v => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  --lookupValue# x selector = undefined

  --query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableSet canLoad exceptions v
  --query# = undefined


instance IsObservableSet canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions Set) v) where
