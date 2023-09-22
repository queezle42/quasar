{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.List (
  ObservableList(..),
  attachSimpleListObserver,
  ToObservableList,
  toObservableList,
  ListDelta(..),
  ValidatedListDelta(..),
  validatedListDeltaLength,
  ListOperation(..),
  Length(..),

  -- * Reexports
  FingerTree,
  Seq,

  -- * Const construction
  empty,
  singleton,
  fromList,
  fromSeq,
  constObservableList,
) where

import Data.Binary (Binary)
import Data.FingerTree (FingerTree, Measured(measure), (<|), ViewL(EmptyL, (:<)), ViewR(EmptyR, (:>)))
import Data.FingerTree qualified as FT
import Data.Sequence (Seq(Empty))
import Data.Sequence qualified as Seq
import Quasar.Observable.Core
import Quasar.Observable.Traversable
import Quasar.Prelude
import Quasar.Resources (TSimpleDisposer)


newtype ListDelta v
  = ListDelta [ListOperation v]
  deriving (Eq, Show, Generic, Binary)

instance Functor ListDelta where
  fmap fn (ListDelta ops) = ListDelta (fn <<$>> ops)

newtype ValidatedListDelta v
  = ValidatedListDelta (FingerTree Length (ListOperation v))
  deriving (Eq, Show, Generic)

instance Functor ValidatedListDelta where
  fmap fn (ValidatedListDelta ops) =
    -- unsafeFmap is safe here because we don't change the length/structure of
    -- the operations.
    ValidatedListDelta (FT.unsafeFmap (fmap fn) ops)

instance Foldable ValidatedListDelta where
  foldMap fn (ValidatedListDelta ops) = foldMap (foldMap fn) ops

instance Traversable ValidatedListDelta where
  traverse fn (ValidatedListDelta ft) =
    -- unsafeTraverse is safe here because we don't change the length/structure
    -- of the operations.
    ValidatedListDelta <$> FT.unsafeTraverse (traverse fn) ft

validatedListDeltaLength :: ValidatedListDelta v -> Length
validatedListDeltaLength (ValidatedListDelta ft) = measure ft

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

instance Functor ListOperation where
  fmap fn (ListInsert xs) = ListInsert (fn <$> xs)
  fmap _fn (ListDrop l) = ListDrop l
  fmap _fn (ListKeep l) = ListKeep l

instance Foldable ListOperation where
  foldMap fn (ListInsert xs) = foldMap fn xs
  foldMap _fn (ListDrop _) = mempty
  foldMap _fn (ListKeep _) = mempty
  foldr fn initial (ListInsert xs) = foldr fn initial xs
  foldr _fn initial (ListDrop _) = initial
  foldr _fn initial (ListKeep _) = initial

instance Traversable ListOperation where
  traverse fn (ListInsert xs) = ListInsert <$> traverse fn xs
  traverse _fn (ListDrop l) = pure (ListDrop l)
  traverse _fn (ListKeep l) = pure (ListKeep l)

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

instance TraversableObservableContainer Seq where
  selectRemoved (ListDelta deltaOps) old = toList (go old deltaOps)
    where
      go
        :: Seq a
        -> [ListOperation v]
        -> Seq a
      go _  [] = []
      go x (ListInsert _ins : ops) = go x ops
      go x (ListDrop count : ops) =
        let (remove, other) = Seq.splitAt (fromIntegral count) x
        in remove <> go other ops
      go x (ListKeep count : ops) =
        go (Seq.drop (fromIntegral count) x) ops

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

toValidatedListDelta :: FingerTree Length (ListOperation v) -> Maybe (ValidatedListDelta v)
toValidatedListDelta ft =
  let normalized = case FT.viewr ft of
        EmptyR -> FT.empty
        (other :> ListDrop _) -> other
        _ -> ft
  in if FT.null normalized
    then Nothing
    else Just (ValidatedListDelta normalized)


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
mergeOperations _old [] = FT.empty
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
  type ValidatedDelta Seq = ValidatedListDelta
  type DeltaContext Seq = Length
  applyDelta (ListDelta ops) state = applyOperations state (toList ops)
  mergeDelta (ValidatedListDelta x) (ListDelta y) =
    ValidatedListDelta (mergeOperations x (toList y))
  validateDelta ctx (ListDelta ops) =
    toValidatedListDelta (updateListDeltaContext ctx ops)
  validatedDeltaToContext = validatedListDeltaLength
  validatedDeltaToDelta (ValidatedListDelta x) = ListDelta (toList x)
  toDeltaContext state = fromIntegral (Seq.length state)
  toDelta = fst
  contentFromEvaluatedDelta = snd

instance ContainerCount Seq where
  containerCount# x = fromIntegral (length x)
  containerIsEmpty# x = null x


type ToObservableList canLoad exceptions v a = ToObservableT canLoad exceptions Seq v a

toObservableList :: ToObservableList canLoad exceptions v a => a -> ObservableList canLoad exceptions v
toObservableList x = ObservableList (toObservableT x)

newtype ObservableList canLoad exceptions v
  = ObservableList (ObservableT canLoad exceptions Seq v)

instance ToObservableT canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  toObservableT (ObservableList x) = x

instance IsObservableCore canLoad exceptions Seq v (ObservableList canLoad exceptions v) where
  readObservable# (ObservableList x) = readObservable# x
  attachObserver# (ObservableList x) = attachObserver# x
  attachEvaluatedObserver# (ObservableList x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableList x) = isCachedObservable# x

instance IsObservableList canLoad exceptions v (ObservableList canLoad exceptions v) where
  --member# (ObservableList (ObservableT x)) = member# x
  --listLookupValue# (ObservableList x) = listLookupValue# x

instance Semigroup (ObservableList canLoad exceptions v) where
  (<>) = undefined

instance Monoid (ObservableList canLoad exceptions v) where
  mempty = fromSeq Seq.empty


class IsObservableCore canLoad exceptions Seq v a => IsObservableList canLoad exceptions v a where
  member# :: Ord v => a -> v -> Observable canLoad exceptions Bool
  member# = undefined

  listLookupValue# :: Ord v => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  listLookupValue# x selector = undefined

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableList canLoad exceptions v
  query# = undefined


instance IsObservableList canLoad exceptions v (ObservableState canLoad (ObservableResult exceptions Seq) v) where

attachSimpleListObserver ::
  ObservableList NoLoad '[] v ->
  (ObservableUpdate Seq v -> STMc NoRetry '[] ()) ->
  STMc NoRetry '[] (TSimpleDisposer, Seq v)
attachSimpleListObserver observable callback = do
  (disposer, initial) <- attachObserver# observable \case
    ObservableChangeLiveReplace (ObservableResultTrivial new) -> callback (ObservableUpdateReplace new)
    ObservableChangeLiveDelta delta -> callback (ObservableUpdateDelta delta)
  case initial of
    ObservableStateLive (ObservableResultTrivial x) -> pure (disposer, x)

constObservableList :: ObservableState canLoad (ObservableResult exceptions Seq) v -> ObservableList canLoad exceptions v
constObservableList = ObservableList . ObservableT

fromList :: [v] -> ObservableList canLoad exceptions v
fromList = fromSeq . Seq.fromList

fromSeq :: Seq v -> ObservableList canLoad exceptions v
fromSeq = constObservableList . ObservableStateLive . ObservableResultOk

singleton :: v -> ObservableList canLoad exceptions v
singleton = ObservableList . ObservableT . fromSeq . Seq.singleton

empty :: ObservableList canLoad exceptions v
empty = mempty
