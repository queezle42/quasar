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


data ObservableSetDelta v
  = ObservableSetUpdate (Set (ObservableSetOperation v))
  | ObservableSetReplace (Set v)

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
  type EvaluatedDelta Set v = (ObservableSetDelta v, Set v)
  type Key Set v = v
  applyDelta (ObservableSetReplace new) _ = new
  applyDelta (ObservableSetUpdate ops) old = applyObservableSetOperations ops old
  mergeDelta _ new@ObservableSetReplace{} = new
  mergeDelta (ObservableSetUpdate old) (ObservableSetUpdate new) = ObservableSetUpdate (Set.union new old)
  mergeDelta (ObservableSetReplace old) (ObservableSetUpdate new) = ObservableSetReplace (applyObservableSetOperations new old)
  toInitialDelta = ObservableSetReplace
  initializeFromDelta (ObservableSetReplace new) = new
  -- TODO replace with safe implementation once the module is tested
  initializeFromDelta _ = error "ObservableSet.initializeFromDelta: expected ObservableSetReplace"
  toDelta = fst
  toEvaluatedDelta = (,)
  toEvaluatedContent = snd

instance ContainerCount Set where
  containerCount# x = fromIntegral (Set.size x)
  containerIsEmpty# x = Set.null x


type ToObservableSet canLoad exceptions v = ToObservableT canLoad exceptions Set v

toObservableSet :: ToObservableSet canLoad exceptions v a => a -> ObservableSet canLoad exceptions v
toObservableSet x = ObservableSet (toObservableCore x)

newtype ObservableSet canLoad exceptions v = ObservableSet (ObservableT canLoad exceptions Set v)

instance ToObservableT canLoad exceptions Set v (ObservableSet canLoad exceptions v) where
  toObservableCore (ObservableSet x) = x

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
