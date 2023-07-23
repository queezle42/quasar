{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Observable.List (
  ObservableList(..),
  ToObservableList,
  toObservableList,
  ObservableListDelta(..),
  ObservableListOperation(..),

  -- * Reexports
  Seq,
) where

import Data.Binary (Binary)
import Data.Sequence (Seq(Empty, (:<|), (:|>)))
import Data.Sequence qualified as Seq
import Quasar.Observable.Core
import Quasar.Prelude


newtype ObservableListDelta v
  = ObservableListDelta (Seq (ObservableListOperation v))
  deriving Generic

instance Binary v => Binary (ObservableListDelta v)

-- Operations are relative to the end of the previous operation.
data ObservableListOperation v
  = ObservableListInsert Word32 (Seq v)
  | ObservableListDelete Word32 Word32
  deriving Generic

instance Binary v => Binary (ObservableListOperation v)

instance ObservableContainer Seq v where
  type ContainerConstraint canLoad exceptions Seq v a = IsObservableList canLoad exceptions v a
  type Delta Seq = ObservableListDelta
  type Key Seq v = Int
  type DeltaContext Seq = Word32
  applyDelta _delta _state = undefined
  mergeDelta _old _new = undefined
  updateDeltaContext = undefined
  toInitialDeltaContext = undefined
  toDelta = fst
  contentFromEvaluatedDelta = snd

instance ContainerCount Seq where
  containerCount# x = fromIntegral (length x)
  containerIsEmpty# x = null x


type ToObservableList canLoad exceptions v a = ToObservableT canLoad exceptions Seq v a

toObservableList :: ToObservableList canLoad exceptions v a => a -> ObservableList canLoad exceptions v
toObservableList x = ObservableList (toObservableCore x)

newtype ObservableList canLoad exceptions v
  = ObservableList (ObservableT canLoad exceptions Seq v)

instance ToObservableT canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  toObservableCore (ObservableList x) = x

instance IsObservableCore canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  readObservable# (ObservableList x) = readObservable# x
  attachObserver# (ObservableList x) = attachObserver# x
  attachEvaluatedObserver# (ObservableList x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableList x) = isCachedObservable# x

instance IsObservableList canLoad exceptions v (ObservableList canLoad exceptions v) where
  --member# (ObservableList (ObservableT x)) = member# x
  --listLookupValue# (ObservableList x) = listLookupValue# x


class IsObservableCore canLoad exceptions Seq v a => IsObservableList canLoad exceptions v a where
  member# :: Ord v => a -> v -> Observable canLoad exceptions Bool
  member# = undefined

  listLookupValue# :: Ord v => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  listLookupValue# x selector = undefined

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableList canLoad exceptions v
  query# = undefined


instance IsObservableList canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions Seq) v) where
