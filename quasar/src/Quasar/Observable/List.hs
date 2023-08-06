{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.List (
  ObservableList(..),
  ToObservableList,
  toObservableList,
  ListDelta(..),
  ListDeltaCtx(..),
  ListOperation(..),
  Length,

  -- * Reexports
  FingerTree,
  Seq,
) where

import Data.Binary (Binary)
import Data.Sequence (Seq(Empty))
import Data.Sequence qualified as Seq
import Quasar.Observable.Core
import Quasar.Prelude
import Data.FingerTree (FingerTree, Measured(measure), (<|), ViewL(EmptyL, (:<)))
import Data.FingerTree qualified as FT
import GHC.IsList (IsList, Item)
import GHC.IsList qualified as IsList


instance Measured v a => IsList (FingerTree v a) where
  type Item (FingerTree v a) = a
  fromList = FT.fromList
  toList = toList



newtype ListDelta v
  = ListDelta [ListOperation v]
  deriving (Eq, Show, Generic, Binary)

newtype ListDeltaCtx v
  = ListDeltaCtx (FingerTree Length (ListOperation v))
  deriving (Eq, Show, Generic)

newtype Length = Length Word32
  deriving (Show, Eq, Ord, Enum, Num, Real, Integral, Binary)

instance Monoid Length where
  mempty = Length 0

instance Semigroup Length where
  Length x <> Length y = Length (x + y)

-- Operations are relative to the end of the previous operation.
data ListOperation v
  = ListInsert (Seq v)
  | ListDrop Length
  | ListKeep Length
  deriving (Eq, Show, Generic)

instance Binary v => Binary (ListOperation v)

instance Measured Length (ListOperation v) where
  measure (ListInsert ins) = fromIntegral (Seq.length ins)
  measure (ListDrop _) = 0
  measure (ListKeep n) = n

applyOperations
  :: Seq v
  -> [ListOperation v]
  -> Seq v
applyOperations _  [] = []
applyOperations x (ListInsert ins : ops) = ins <> applyOperations x ops
applyOperations x (ListDrop count : ops) =
  applyOperations (Seq.drop (fromIntegral count) x) ops
applyOperations x (ListKeep count : ops) =
  let (keep, other) = Seq.splitAt (fromIntegral count) x
  in keep <> applyOperations other ops
  where

instance ObservableContainer Seq v where
  type ContainerConstraint canLoad exceptions Seq v a = IsObservableList canLoad exceptions v a
  mergeDelta _old _new = undefined
  type Delta Seq = ListDelta
  type DeltaWithContext Seq v = ListDeltaCtx v
  type DeltaContext Seq = Length
  applyDelta (ListDelta ops) state = Just (applyOperations state (toList ops))
  updateDeltaContext ctx (ListDelta ops) = undefined -- updateLength ctx ops
  toInitialDeltaContext state = fromIntegral (Seq.length state)
  toDelta = fst
  contentFromEvaluatedDelta = snd
  splitDeltaAndContext (ListDeltaCtx x) = Just (ListDelta (toList x), measure x)

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
