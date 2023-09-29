{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.List (
  ObservableList(..),
  IsObservableList(..),
  attachSimpleListObserver,
  ToObservableList,
  toObservableList,
  ListDelta(..),
  ValidatedListDelta(..),
  validatedListDeltaLength,
  ListDeltaOperation(..),
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

  -- * List operations with absolute addressing
  ListOperation(..),
  updateToOperations,
  operationsToUpdate,

  -- * ObservableListVar (mutable observable var)
  ObservableListVar,
  newObservableListVar,
  newObservableListVarIO,
  insert,
  append,
  delete,
  lookupDelete,
  replace,
  clear,
) where

import Data.Binary (Binary)
import Data.FingerTree (FingerTree, Measured(measure), (<|), ViewL(EmptyL, (:<)), ViewR(EmptyR, (:>)))
import Data.FingerTree qualified as FT
import Data.Sequence (Seq(Empty))
import Data.Sequence qualified as Seq
import Quasar.Observable.Core
import Quasar.Observable.Subject
import Quasar.Observable.Traversable
import Quasar.Prelude
import Quasar.Resources (TSimpleDisposer)
import Data.Foldable (foldl')


newtype ListDelta v
  = ListDelta [ListDeltaOperation v]
  deriving (Eq, Show, Generic, Binary)

instance Functor ListDelta where
  fmap fn (ListDelta ops) = ListDelta (fn <<$>> ops)

newtype ValidatedListDelta v
  = ValidatedListDelta (FingerTree Length (ListDeltaOperation v))
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

-- | Parts of a `ListDelta`. Together they represent instructions to generate
-- a new list from an input list.
--
-- The operations are optimized for efficient implementations of `applyDelta`
-- and `mergeDelta`. For construction from classical list operations
-- (`ListOperation`) see `updateToOperations`.
--
-- Notes:
--
-- - Operations are relative to the end of the previous operation.
-- - The remainder of the input list (everything not taken by a `ListKeep`) is
--   dropped when applying the delta.
data ListDeltaOperation v
  = ListSplice (Seq v) -- ^ Append the provided list to the end of the result list.
  | ListDrop Length -- ^ Skip @n@ elements from the start of the input list.
  | ListKeep Length -- ^ Take @n@ elements from the start of the input list and append them to the result list.
  deriving (Eq, Show, Generic)

instance Functor ListDeltaOperation where
  fmap fn (ListSplice xs) = ListSplice (fn <$> xs)
  fmap _fn (ListDrop l) = ListDrop l
  fmap _fn (ListKeep l) = ListKeep l

instance Foldable ListDeltaOperation where
  foldMap fn (ListSplice xs) = foldMap fn xs
  foldMap _fn (ListDrop _) = mempty
  foldMap _fn (ListKeep _) = mempty
  foldr fn initial (ListSplice xs) = foldr fn initial xs
  foldr _fn initial (ListDrop _) = initial
  foldr _fn initial (ListKeep _) = initial

instance Traversable ListDeltaOperation where
  traverse fn (ListSplice xs) = ListSplice <$> traverse fn xs
  traverse _fn (ListDrop l) = pure (ListDrop l)
  traverse _fn (ListKeep l) = pure (ListKeep l)

instance Binary v => Binary (ListDeltaOperation v)

instance Measured Length (ListDeltaOperation v) where
  measure (ListSplice ins) = fromIntegral (Seq.length ins)
  measure (ListDrop _) = 0
  measure (ListKeep n) = n

applyDeltaOperations
  :: Seq v
  -> [ListDeltaOperation v]
  -> Seq v
applyDeltaOperations _  [] = []
applyDeltaOperations x (ListSplice ins : ops) = ins <> applyDeltaOperations x ops
applyDeltaOperations x (ListDrop count : ops) =
  applyDeltaOperations (Seq.drop (fromIntegral count) x) ops
applyDeltaOperations x (ListKeep count : ops) =
  let (keep, other) = Seq.splitAt (fromIntegral count) x
  in keep <> applyDeltaOperations other ops

instance TraversableObservableContainer Seq where
  selectRemoved (ListDelta deltaOps) old = toList (go old deltaOps)
    where
      go
        :: Seq a
        -> [ListDeltaOperation v]
        -> Seq a
      go _  [] = []
      go x (ListSplice _ins : ops) = go x ops
      go x (ListDrop count : ops) =
        let (remove, other) = Seq.splitAt (fromIntegral count) x
        in remove <> go other ops
      go x (ListKeep count : ops) =
        go (Seq.drop (fromIntegral count) x) ops

updateListDeltaContext :: Length -> [ListDeltaOperation v] -> FingerTree Length (ListDeltaOperation v)
updateListDeltaContext _l [] = FT.empty
updateListDeltaContext 0 ops = mergeOperationsEmpty ops
updateListDeltaContext l (ListSplice ins : ops) = prependInsert ins (updateListDeltaContext l ops)
updateListDeltaContext l (ListKeep n : ops) =
  if l > n
    then prependKeep n (updateListDeltaContext (l - n) ops)
    else prependKeep l (updateListDeltaContext 0 ops)
updateListDeltaContext l (ListDrop n : ops) =
  if l > n
    then prependDrop n (updateListDeltaContext (l - n) ops)
    else prependDrop l (updateListDeltaContext 0 ops)

toValidatedListDelta :: FingerTree Length (ListDeltaOperation v) -> Maybe (ValidatedListDelta v)
toValidatedListDelta ft = Just $ ValidatedListDelta
  case FT.viewr ft of
    (other :> ListDrop _) -> other
    _ -> ft


prependInsert :: Seq v -> FingerTree Length (ListDeltaOperation v) -> FingerTree Length (ListDeltaOperation v)
prependInsert Empty ft = ft
prependInsert new ft =
  case FT.viewl ft of
    (ListSplice ins :< others) -> ListSplice (new <> ins) <| others
    _ -> ListSplice new <| ft

prependKeep :: Length -> FingerTree Length (ListDeltaOperation v) -> FingerTree Length (ListDeltaOperation v)
prependKeep 0 ft = ft
prependKeep l ft =
  case FT.viewl ft of
    (ListKeep d :< others) -> ListKeep (l + d) <| others
    _ -> ListKeep l <| ft

prependDrop :: Length -> FingerTree Length (ListDeltaOperation v) -> FingerTree Length (ListDeltaOperation v)
prependDrop 0 ft = ft
prependDrop l ft =
  case FT.viewl ft of
    (ListDrop d :< others) -> ListDrop (l + d) <| others
    _ -> ListDrop l <| ft

joinOps :: FingerTree Length (ListDeltaOperation v) -> FingerTree Length (ListDeltaOperation v) -> FingerTree Length (ListDeltaOperation v)
joinOps x y =
  case (FT.viewr x, FT.viewl y) of
    (_, EmptyL) -> x
    (EmptyR, _) -> y
    (xs :> ListSplice xi, ListSplice yi :< ys) -> xs <> (ListSplice (xi <> yi) <| ys)
    (xs :> ListKeep xi, ListKeep yi :< ys) -> xs <> (ListKeep (xi + yi) <| ys)
    (xs :> ListDrop xi, ListDrop yi :< ys) -> xs <> (ListDrop (xi + yi) <| ys)
    _ -> x <> y


mergeDeltaOperations ::
  FingerTree Length (ListDeltaOperation v) ->
  [ListDeltaOperation v] ->
  FingerTree Length (ListDeltaOperation v)
mergeDeltaOperations _old [] = FT.empty
mergeDeltaOperations old (ListSplice ins : ops) =
  prependInsert ins (mergeDeltaOperations old ops)
mergeDeltaOperations old (ListDrop n : ops)
  | n > FT.measure old =
    -- Dropping (at least) the remainder of the input list.
    mergeOperationsEmpty ops
  | otherwise = mergeDeltaOperations (dropN n old) ops
mergeDeltaOperations old (ListKeep n : ops)
  | n > FT.measure old =
    -- Keeping the remainder of the input list.
    old `joinOps` mergeOperationsEmpty ops
  | otherwise =
    let (pre, post) = splitOpsAt n old
    in pre `joinOps`  mergeDeltaOperations post ops

mergeOperationsEmpty ::
  [ListDeltaOperation v] ->
  FingerTree Length (ListDeltaOperation v)
mergeOperationsEmpty x =
  case go x of
    Empty -> FT.empty
    finalIns -> FT.singleton (ListSplice finalIns)
  where
    go :: [ListDeltaOperation v] -> Seq v
    go [] = Empty
    go (ListSplice ins : ops) = ins <> go ops
    go (_ : ops) = go ops


dropN ::
  Length ->
  FingerTree Length (ListDeltaOperation v) ->
  FingerTree Length (ListDeltaOperation v)
dropN 0 ops = ops
dropN n ops =
  case FT.viewl ops of
    EmptyL -> FT.empty
    ListSplice ins :< other ->
      let insLength = fromIntegral (length ins)
      in if n >= insLength
        then dropN (n - insLength) other
        else ListSplice (Seq.drop (fromIntegral n) ins) <| other
    x@(ListDrop _) :< other -> x <| dropN n other
    ListKeep k :< other ->
      if n >= k
        then ListDrop k <| dropN (n - k) other
        else ListDrop n <| ListKeep (k - n) <| other


splitOpsAt ::
  Length ->
  FingerTree Length (ListDeltaOperation v) ->
  (FingerTree Length (ListDeltaOperation v), FingerTree Length (ListDeltaOperation v))
splitOpsAt n ops =
  let (pre, curr) = FT.split (>= n) ops
  in case FT.viewl curr of
    EmptyL -> (pre, FT.empty)
    middle :< post ->
      let (mpre, mpost) = splitOpAt (n - measure pre) middle
      in (pre <> mpre, mpost <> post)

splitOpAt ::
  Length ->
  ListDeltaOperation v ->
  (FingerTree Length (ListDeltaOperation v), FingerTree Length (ListDeltaOperation v))
splitOpAt _ (ListDrop d) = (FT.singleton (ListDrop d), FT.empty)
splitOpAt 0 op = (FT.empty, FT.singleton op)
splitOpAt n (ListSplice ins) =
  case Seq.splitAt (fromIntegral n) ins of
    (pre, Empty) -> (FT.singleton (ListSplice pre), FT.empty)
    (pre, post) -> (FT.singleton (ListSplice pre), FT.singleton (ListSplice post))
splitOpAt n (ListKeep k)
  | n >= k = (FT.singleton (ListKeep k), FT.empty)
  | otherwise = (FT.singleton (ListKeep n), FT.singleton (ListKeep (k - n)))


instance ObservableContainer Seq v where
  type ContainerConstraint canLoad exceptions Seq v a = IsObservableList canLoad exceptions v a
  type Delta Seq = ListDelta
  type ValidatedDelta Seq = ValidatedListDelta
  type DeltaContext Seq = Length
  applyDelta (ListDelta ops) state = Just (applyDeltaOperations state (toList ops))
  mergeDelta (ValidatedListDelta x) (ListDelta y) =
    ValidatedListDelta (mergeDeltaOperations x (toList y))
  validateDelta ctx (ListDelta ops) =
    toValidatedListDelta (updateListDeltaContext ctx ops)
  validatedDeltaToContext = validatedListDeltaLength
  validatedDeltaToDelta (ValidatedListDelta x) = ListDelta (toList x)
  toDeltaContext state = fromIntegral (Seq.length state)

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

instance IsObservableList canLoad exceptions v (MappedObservable canLoad exceptions Seq v) where

instance Functor (ObservableList canLoad exceptions) where
  fmap fn (ObservableList fx) = ObservableList (ObservableT (mapObservable# fn fx))

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


data ListOperation v
  = ListInsert Length v -- ^ Insert before element n.
  | ListAppend v -- ^ Append at the end of the list.
  | ListDelete Length -- ^ Delete element with index n.
  | ListReplaceAll (Seq v)

updateToOperations :: Length -> ObservableUpdate Seq v -> [ListOperation v]
updateToOperations _initialLength (ObservableUpdateReplace new) = [ListReplaceAll new]
updateToOperations initialLength (ObservableUpdateDelta (ListDelta initialOps)) =
  go 0 initialLength initialOps
  where
    go :: Length -> Length -> [ListDeltaOperation v] -> [ListOperation v]
    -- Delete remainder, if there is any
    go _offset 0 [] = []
    go offset remaining [] = ListDelete offset : go (offset + 1) (remaining -1) []

    go offset 0 (ListSplice xs : ops) = (ListAppend <$> toList xs) <> go (offset + fromIntegral (Seq.length xs)) 0 ops
    go offset remaining (ListSplice Seq.Empty : ops) = go offset remaining ops
    go offset remaining (ListSplice (x Seq.:<| xs) : ops) = ListInsert offset x : go (offset + 1) remaining (ListSplice xs : ops)

    go offset remaining (ListKeep n : ops) = go (offset + n) (remaining - n) ops

    go offset remaining (ListDrop count : ops)
      | count < remaining = replicate (fromIntegral count) (ListDelete offset) <> go offset (remaining - count) ops
      | otherwise = replicate (fromIntegral remaining) (ListDelete offset) <> go offset 0 ops


operationsToUpdate :: Length -> [ListOperation v] -> Maybe (ObservableUpdate Seq v)
operationsToUpdate _initialLength [] = Nothing
operationsToUpdate initialLength (op:ops) =
  let initial = operationToValidatedUpdate initialLength op
  in unvalidatedUpdate (foldl applyListOperationToUpdate initial ops)


applyListOperationToUpdate ::
  Either (DeltaContext Seq) (ValidatedUpdate Seq v) ->
  ListOperation v ->
  Either (DeltaContext Seq) (ValidatedUpdate Seq v)
applyListOperationToUpdate oldUpdate op =
  let newUpdate = operationToValidatedUpdate (validatedUpdateToContext oldUpdate) op
  in mergeValidatedUpdate oldUpdate (unvalidatedUpdate newUpdate)

operationToValidatedUpdate :: Length -> ListOperation v -> Either Length (ValidatedUpdate Seq v)
operationToValidatedUpdate len (ListInsert pos value) = Right
  if len > 0
    then ValidatedUpdateDelta $ ValidatedListDelta $ FT.fromList
      if pos < len
        then [ListKeep pos, ListSplice [value], ListKeep (len - pos)]
        else [ListKeep len, ListSplice [value]]
    else ValidatedUpdateReplace [value]
operationToValidatedUpdate len (ListAppend value) = Right
  if len > 0
    then ValidatedUpdateDelta $ ValidatedListDelta $ FT.fromList [ListKeep len, ListSplice [value]]
    else ValidatedUpdateReplace [value]
operationToValidatedUpdate len (ListDelete pos) =
  if pos < len
    then Right if len == 1
      then ValidatedUpdateReplace []
      else ValidatedUpdateDelta $ ValidatedListDelta
        if pos == 0
          then FT.fromList [ListDrop 1, ListKeep (len - 1)]
          else if pos == (len - 1)
            then FT.singleton (ListKeep pos)
            else FT.fromList [ListKeep pos, ListDrop 1, ListKeep (len - pos - 1)]
    else Left len
operationToValidatedUpdate 0 (ListReplaceAll []) = Left 0
operationToValidatedUpdate _len (ListReplaceAll new) = Right (ValidatedUpdateReplace new)


-- * ObservableListVar

newtype ObservableListVar v = ObservableListVar (Subject NoLoad '[] Seq v)

deriving newtype instance IsObservableCore NoLoad '[] Seq v (ObservableListVar v)
deriving newtype instance IsObservableList NoLoad '[] v (ObservableListVar v)
deriving newtype instance ToObservableT NoLoad '[] Seq v (ObservableListVar v)

instance IsObservableList l e v (Subject l e Seq v)
  -- TODO

newObservableListVar :: MonadSTMc NoRetry '[] m => Seq v -> m (ObservableListVar v)
newObservableListVar x = liftSTMc @NoRetry @'[] $ ObservableListVar <$> newSubject x

newObservableListVarIO :: MonadIO m => Seq v -> m (ObservableListVar v)
newObservableListVarIO x = liftIO $ ObservableListVar <$> newSubjectIO x

-- | Apply a list of `AbsoluteListDeltaOperation`s as a single change.
applyListOperations :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> [ListOperation v] -> m ()
applyListOperations (ObservableListVar var) ops =
  updateSimpleSubject var \list ->
    operationsToUpdate (fromIntegral (Seq.length list)) ops

insert :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> Length -> v -> m ()
insert var pos value = applyListOperations var [ListInsert pos value]

append :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> v -> m ()
append var value = applyListOperations var [ListAppend value]

delete :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> Length -> m ()
delete var pos = applyListOperations var [ListDelete pos]

lookupDelete :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> Length -> m (Maybe v)
lookupDelete var@(ObservableListVar subject) pos = do
  state <- readSubject subject
  let r = Seq.lookup (fromIntegral pos) state
  when (isJust r) $ delete var pos
  pure r

replace :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> Seq v -> m ()
replace var new = applyListOperations var [ListReplaceAll new]

clear :: (MonadSTMc NoRetry '[] m) => ObservableListVar v -> m ()
clear var = replace var mempty
