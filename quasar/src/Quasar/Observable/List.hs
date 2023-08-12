{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.List (
  ObservableList(..),
  ToObservableList,
  toObservableList,
  ListDelta(..),
  ListDeltaCtx(..),
  listDeltaCtxLength,
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
import Data.FingerTree (FingerTree, Measured(measure), (<|), ViewL(EmptyL, (:<)), ViewR(EmptyR, (:>)))
import Data.FingerTree qualified as FT


newtype ListDelta v
  = ListDelta [ListOperation v]
  deriving (Eq, Show, Generic, Binary)

newtype ListDeltaCtx v
  = ListDeltaCtx (FingerTree Length (ListOperation v))
  deriving (Eq, Show, Generic)

listDeltaCtxLength :: ListDeltaCtx v -> Length
listDeltaCtxLength (ListDeltaCtx ft) = measure ft

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

updateListDeltaContext :: Length -> [ListOperation v] -> FingerTree Length (ListOperation v)
updateListDeltaContext _l [] = FT.empty
updateListDeltaContext 0 ops = mergeOperationsEmpty ops
updateListDeltaContext l (ListInsert ins : ops) = prependInsert ins (updateListDeltaContext l ops)
updateListDeltaContext l (ListKeep n : ops) =
  if l > n
    then prependKeep n (updateListDeltaContext (l - n) ops)
    else prependKeep l (updateListDeltaContext 0 ops)
updateListDeltaContext l (ListDrop n : ops) =
  if l > n
    then prependDrop n (updateListDeltaContext (l - n) ops)
    else prependDrop l (updateListDeltaContext 0 ops)

toListDeltaCtx :: FingerTree Length (ListOperation v) -> ListDeltaCtx v
toListDeltaCtx ft =
  ListDeltaCtx case FT.viewr ft of
    EmptyR -> FT.empty
    (other :> ListDrop _) -> other
    _ -> ft


prependInsert :: Seq v -> FingerTree Length (ListOperation v) -> FingerTree Length (ListOperation v)
prependInsert Empty ft = ft
prependInsert new ft =
  case FT.viewl ft of
    (ListInsert ins :< others) -> ListInsert (new <> ins) <| others
    _ -> ListInsert new <| ft

prependKeep :: Length -> FingerTree Length (ListOperation v) -> FingerTree Length (ListOperation v)
prependKeep 0 ft = ft
prependKeep l ft =
  case FT.viewl ft of
    (ListKeep d :< others) -> ListKeep (l + d) <| others
    _ -> ListKeep l <| ft

prependDrop :: Length -> FingerTree Length (ListOperation v) -> FingerTree Length (ListOperation v)
prependDrop 0 ft = ft
prependDrop l ft =
  case FT.viewl ft of
    (ListDrop d :< others) -> ListDrop (l + d) <| others
    _ -> ListDrop l <| ft

joinOps :: FingerTree Length (ListOperation v) -> FingerTree Length (ListOperation v) -> FingerTree Length (ListOperation v)
joinOps x y =
  case (FT.viewr x, FT.viewl y) of
    (_, EmptyL) -> x
    (EmptyR, _) -> y
    (xs :> ListInsert xi, ListInsert yi :< ys) -> xs <> (ListInsert (xi <> yi) <| ys)
    (xs :> ListKeep xi, ListKeep yi :< ys) -> xs <> (ListKeep (xi + yi) <| ys)
    (xs :> ListDrop xi, ListDrop yi :< ys) -> xs <> (ListDrop (xi + yi) <| ys)
    _ -> x <> y


mergeOperations ::
  FingerTree Length (ListOperation v) ->
  [ListOperation v] ->
  FingerTree Length (ListOperation v)
mergeOperations old [] = FT.empty
mergeOperations old (ListInsert ins : ops) =
  prependInsert ins (mergeOperations old ops)
mergeOperations old (ListDrop n : ops)
  | n > FT.measure old =
    -- Dropping (at least) the remainder of the input list.
    mergeOperationsEmpty ops
  | otherwise = mergeOperations (dropN n old) ops
mergeOperations old (ListKeep n : ops)
  | n > FT.measure old =
    -- Keeping the remainder of the input list.
    old `joinOps` mergeOperationsEmpty ops
  | otherwise =
    let (pre, post) = splitOpsAt n old
    in pre `joinOps`  mergeOperations post ops

mergeOperationsEmpty ::
  [ListOperation v] ->
  FingerTree Length (ListOperation v)
mergeOperationsEmpty x =
  case go x of
    Empty -> FT.empty
    finalIns -> FT.singleton (ListInsert finalIns)
  where
    go :: [ListOperation v] -> Seq v
    go [] = Empty
    go (ListInsert ins : ops) = ins <> go ops
    go (_ : ops) = go ops


dropN ::
  Length ->
  FingerTree Length (ListOperation v) ->
  FingerTree Length (ListOperation v)
dropN 0 ops = ops
dropN n ops =
  case FT.viewl ops of
    EmptyL -> FT.empty
    ListInsert ins :< other ->
      let insLength = fromIntegral (length ins)
      in if n >= insLength
        then dropN (n - insLength) other
        else ListInsert (Seq.drop (fromIntegral n) ins) <| other
    x@(ListDrop _) :< other -> x <| dropN n other
    ListKeep k :< other ->
      if n >= k
        then ListDrop k <| dropN (n - k) other
        else ListDrop n <| ListKeep (k - n) <| other


splitOpsAt ::
  Length ->
  FingerTree Length (ListOperation v) ->
  (FingerTree Length (ListOperation v), FingerTree Length (ListOperation v))
splitOpsAt n ops =
  let (pre, curr) = FT.split (>= n) ops
  in case FT.viewl curr of
    EmptyL -> (pre, FT.empty)
    middle :< post ->
      let (mpre, mpost) = splitOpAt (n - measure pre) middle
      in (pre <> mpre, mpost <> post)

splitOpAt ::
  Length ->
  ListOperation v ->
  (FingerTree Length (ListOperation v), FingerTree Length (ListOperation v))
splitOpAt _ (ListDrop d) = (FT.singleton (ListDrop d), FT.empty)
splitOpAt 0 op = (FT.empty, FT.singleton op)
splitOpAt n (ListInsert ins) =
  case Seq.splitAt (fromIntegral n) ins of
    (pre, Empty) -> (FT.singleton (ListInsert pre), FT.empty)
    (pre, post) -> (FT.singleton (ListInsert pre), FT.singleton (ListInsert post))
splitOpAt n (ListKeep k)
  | n >= k = (FT.singleton (ListKeep k), FT.empty)
  | otherwise = (FT.singleton (ListKeep n), FT.singleton (ListKeep (k - n)))


instance ObservableContainer Seq v where
  type ContainerConstraint canLoad exceptions Seq v a = IsObservableList canLoad exceptions v a
  type Delta Seq = ListDelta
  type DeltaWithContext Seq v = ListDeltaCtx v
  type DeltaContext Seq = Length
  applyDelta (ListDelta ops) state = Just (applyOperations state (toList ops))
  mergeDelta (ListDeltaCtx x) (ListDelta y) =
    ListDeltaCtx (mergeOperations x (toList y))
  updateDeltaContext ctx (ListDelta ops) =
    let ft = updateListDeltaContext ctx ops
    in (toListDeltaCtx ft, measure ft)
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
