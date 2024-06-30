{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Set (
  ObservableSet,
  ToObservableSet,
  toObservableSet,
  SetDelta(..),
  SetOperation(..),
  share,
  skipUpdateIfEqual,

  -- * Observable interaction
  bindObservable,

  -- ** Const construction
  empty,
  singleton,
  fromSet,
  fromList,
  constObservableSet,

  -- ** Query
  count,
  isEmpty,

  -- ** Combine
  union,

  -- ** Conversions
  toObservableList,
  fromObservableList,

  -- ** Map & Filter
  map,
  mapMaybe,
  filter,

  -- * Traversal
  attachForEach,

  -- * ObservableSetVar (mutable observable var)
  ObservableSetVar(..),
  newVar,
  newVarIO,
  readVar,
  readVarIO,
  insertVar,
  deleteVar,
  replaceVar,
  clearVar,
) where

import Data.Foldable (foldl')
import Data.Maybe qualified as Maybe
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Quasar.Disposer (TDisposer)
import Quasar.Observable.Core hiding (skipUpdateIfEqual)
import Quasar.Observable.List (ObservableList, ListOperation, IsObservableList(..))
import Quasar.Observable.List qualified as ObservableList
import Quasar.Observable.Share
import Quasar.Observable.Subject
import Quasar.Prelude hiding (filter, map)


newtype SetDelta v
  = SetDelta (Map v SetOperation)

data SetOperation = Insert | Delete
  deriving (Eq, Ord)


insertDelta :: v -> SetDelta v
insertDelta value = SetDelta (Map.singleton value Insert)

deleteDelta :: v -> SetDelta v
deleteDelta value = SetDelta (Map.singleton value Delete)


applyObservableSetOperation :: Ord v => (v, SetOperation) -> Set v -> Set v
applyObservableSetOperation (x, Insert) = Set.insert x
applyObservableSetOperation (x, Delete) = Set.delete x

applyObservableSetOperations :: Ord v => [(v, SetOperation)] -> Set v -> Set v
applyObservableSetOperations ops old = foldr applyObservableSetOperation old ops

instance Ord v => ObservableContainer Set v where
  type ContainerConstraint canLoad exceptions Set v a = IsObservableSet canLoad exceptions v a
  type Delta Set = SetDelta
  applyDelta (SetDelta ops) old = Just (applyObservableSetOperations (Map.toList ops) old)
  mergeDelta (SetDelta old) (SetDelta new) = SetDelta (Map.unionWith (\x _ -> x) new old)

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
  isSharedObservable# (ObservableSet x) = isSharedObservable# x

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



instance Ord v => IsObservableSet canLoad exceptions v (SharedObservable canLoad exceptions Set v) where

share ::
  (MonadSTMc NoRetry '[] m, Ord v) =>
  ObservableSet l e v ->
  m (ObservableSet l e v)
share (ObservableSet f) = ObservableSet <$> shareObservableT f

instance (Ord v, IsObservableCore l e Set v b) => IsObservableSet l e v (BindObservable l e ea va b) where

bindObservable ::
  forall l e v va. Ord v =>
  Observable l e va ->
  (va -> ObservableSet l e v) ->
  ObservableSet l e v
bindObservable fx fn = ObservableSet (bindObservableT fx ((\(ObservableSet x) -> x) . fn))

constObservableSet :: ObservableState canLoad (ObservableResult exceptions Set) v -> ObservableSet canLoad exceptions v
constObservableSet = ObservableSet . ObservableT

fromSet :: Set v -> ObservableSet canLoad exceptions v
fromSet = constObservableSet . ObservableStateLive . ObservableResultOk

fromList :: Ord v => [v] -> ObservableSet canLoad exceptions v
fromList = fromSet . Set.fromList

singleton :: v -> ObservableSet canLoad exceptions v
singleton = fromSet . Set.singleton

empty :: Ord v => ObservableSet canLoad exceptions v
empty = fromSet mempty

count :: Ord v => ObservableSet l e v -> Observable l e Int64
count = count#

isEmpty :: Ord v => ObservableSet l e v -> Observable l e Bool
isEmpty = isEmpty#

attachForEach ::
  Ord va =>
  (va -> STMc NoRetry '[] v) ->
  (v -> STMc NoRetry '[] ()) ->
  ObservableSet l e va ->
  STMc NoRetry '[] TDisposer
attachForEach addFn removeFn fx = ObservableList.attachForEach addFn removeFn (toObservableList fx)



data ObservableSetUnion canLoad exceptions v =
  ObservableSetUnion
    (ObservableSet canLoad exceptions v)
    (ObservableSet canLoad exceptions v)

instance Ord v => IsObservableSet canLoad exceptions v (ObservableSetUnion canLoad exceptions v) where

instance Ord v => IsObservableCore canLoad exceptions Set v (ObservableSetUnion canLoad exceptions v) where
  isEmpty# (ObservableSetUnion x y) = do
    xEmpty <- isEmpty# x
    yEmpty <- isEmpty# y
    pure (xEmpty && yEmpty)

  readObservable# (ObservableSetUnion fx fy) = do
    readObservable# fx >>= \case
      ObservableStateLoading -> pure ObservableStateLoading
      (ObservableStateLive (ObservableResultEx ex)) -> pure (ObservableStateLive (ObservableResultEx ex))
      (ObservableStateLive (ObservableResultOk x)) -> do
        y <- readObservable# fy
        pure (mapObservableStateResult (Set.union x) y)

  attachObserver# (ObservableSetUnion fx fy) =
    attachMonoidMergeObserver Set.union deltaFn deltaFn fx fy
    where
      deltaFn :: ObservableUpdate Set  v -> Set v -> Set v -> Maybe (ObservableUpdate Set v)
      deltaFn (ObservableUpdateDelta (SetDelta ops)) _prev other =
        Just (ObservableUpdateDelta (SetDelta (Map.mapMaybeWithKey helper ops)))
        where
          helper :: v -> SetOperation -> Maybe SetOperation
          helper x Insert =
            if Set.member x other
              then Nothing
              else Just Insert
          helper x Delete =
            if Set.member x other
              then Nothing
              else Just Delete
      deltaFn (ObservableUpdateReplace new) prev other =
        deltaFn (ObservableUpdateDelta (SetDelta (Map.union (Map.fromSet (const Insert) new) (Map.fromSet (const Delete) prev)))) prev other



union :: Ord v => ObservableSet l e v -> ObservableSet l e v -> ObservableSet l e v
union x y = ObservableSet (ObservableT (ObservableSetUnion x y))

instance Ord v => Semigroup (ObservableSet l e v) where
  (<>) = union

instance Ord v => Monoid (ObservableSet l e v) where
  mempty = empty



setMapMaybe :: Ord v => (va -> Maybe v) -> Set va -> Set v
setMapMaybe fn = Set.fromList . Maybe.mapMaybe fn . Set.toList

data MapMaybeObservableSet l e va v = MapMaybeObservableSet (va -> Maybe v) (ObservableSet l e va)

instance (Ord va, Ord v) => IsObservableSet l e v (MapMaybeObservableSet l e va v) where

instance (Ord va, Ord v) => IsObservableCore l e Set v (MapMaybeObservableSet l e va v) where
  readObservable# (MapMaybeObservableSet fn x) =
    mapObservableStateResult (setMapMaybe fn) <$> readObservable# x

  attachObserver# (MapMaybeObservableSet fn (ObservableSet x)) =
    attachDeltaRemappingObserver x (setMapMaybe fn) convertDelta
    where
    convertDelta :: Set va -> SetDelta va -> Maybe (ObservableUpdate Set v)
    convertDelta _ (SetDelta setOps) =
      let filteredOps = mapSetOps setOps
      in if Map.null filteredOps
        then Nothing
        else Just (ObservableUpdateDelta (SetDelta filteredOps))

    mapSetOps :: Map va SetOperation -> Map v SetOperation
    mapSetOps = Map.fromList . Maybe.mapMaybe mapSetOp . Map.toList

    mapSetOp :: (va, SetOperation) -> Maybe (v, SetOperation)
    mapSetOp (a, b) = (, b) <$> fn a


-- | \(O(n \log n)\).
mapMaybe :: (Ord va, Ord v) => (va -> Maybe v) -> ObservableSet l e va -> ObservableSet l e v
mapMaybe fn x = ObservableSet (ObservableT (MapMaybeObservableSet fn x))

-- | \(O(n \log n)\).
map :: (Ord va, Ord v) => (va -> v) -> ObservableSet l e va -> ObservableSet l e v
map fn = mapMaybe (Just . fn)
-- Functor is not possible due to the required `Ord` constraints on `va` and
-- `v`, but a simple `map` is. Luckily the `mapMaybe` can be reused.



data FilteredObservableSet l e v = FilteredObservableSet (v -> Bool) (ObservableSet l e v)

instance Ord v => IsObservableSet l e v (FilteredObservableSet l e v) where

instance Ord v => IsObservableCore l e Set v (FilteredObservableSet l e v) where
  readObservable# (FilteredObservableSet fn x) =
    mapObservableStateResult (Set.filter fn) <$> readObservable# x

  attachObserver# (FilteredObservableSet fn (ObservableSet x)) =
    attachDeltaRemappingObserver x (Set.filter fn) convertDelta
    where
    convertDelta :: Set v -> SetDelta v -> Maybe (ObservableUpdate Set v)
    convertDelta _ (SetDelta setOps) =
      let filteredOps = Map.filterWithKey (const . fn) setOps
      in if Map.null filteredOps
        then Nothing
        else Just (ObservableUpdateDelta (SetDelta filteredOps))


-- | \(O(n)\).
filter :: Ord v => (v -> Bool) -> ObservableSet l e v -> ObservableSet l e v
filter fn x = ObservableSet (ObservableT (FilteredObservableSet fn x))



newtype SkipUpdateIfEqual l e v = SkipUpdateIfEqual (ObservableSet l e v)

instance Ord v => IsObservableSet l e v (SkipUpdateIfEqual l e v) where

instance Ord v => IsObservableCore l e Set v (SkipUpdateIfEqual l e v) where
  readObservable# (SkipUpdateIfEqual x) = readObservable# x

  attachObserver# (SkipUpdateIfEqual (ObservableSet x)) =
    attachDeltaRemappingObserver x id convertDelta
    where
    convertDelta :: Set v -> SetDelta v -> Maybe (ObservableUpdate Set v)
    convertDelta initialSet (SetDelta ops) =
      let (_finalSet, filteredOps) = Map.fromList <$> foldl' convertOperation (initialSet, []) (Map.toList ops)
      in if Map.null filteredOps then Nothing else Just (ObservableUpdateDelta (SetDelta filteredOps))
    convertOperation :: (Set v, [(v, SetOperation)]) -> (v, SetOperation) -> (Set v, [(v, SetOperation)])
    convertOperation (set, operations) (value, Insert) =
      if Set.member value set
        then (set, operations)
        else (Set.insert value set, (value, Insert):operations)
    convertOperation (set, operations) (value, Delete) =
      if Set.member value set
        then (Set.delete value set, (value, Delete):operations)
        else (set, operations)


skipUpdateIfEqual :: Ord v => ObservableSet l e v -> ObservableSet l e v
skipUpdateIfEqual x = ObservableSet (ObservableT (SkipUpdateIfEqual x))



newtype ObservableSetToList canLoad exceptions v = ObservableSetToList (ObservableSet canLoad exceptions v)

instance Ord v => IsObservableList canLoad exceptions v (ObservableSetToList canLoad exceptions v) where

instance Ord v => IsObservableCore canLoad exceptions Seq v (ObservableSetToList canLoad exceptions v) where
  isEmpty# (ObservableSetToList x) = isEmpty# x

  count# (ObservableSetToList x) = count# x

  readObservable# (ObservableSetToList x) =
    mapObservableStateResult (Seq.fromList . Set.elems) <$> readObservable# x

  attachObserver# (ObservableSetToList (ObservableSet x)) =
    attachDeltaRemappingObserver x (Seq.fromList . Set.elems) convertDelta
    where
      convertDelta :: Set v -> SetDelta v -> Maybe (ObservableUpdate Seq v)
      convertDelta s (SetDelta ops) =
        let (_finalSet, listOps) = foldl' addOperation (s, []) (Map.toList ops)
        in ObservableList.operationsToUpdate (fromIntegral (Set.size s)) listOps

      addOperation :: (Set v, [ListOperation v]) -> (v, SetOperation) -> (Set v, [ListOperation v])
      addOperation (s, listOps) setOp = (listOps <>) <$> convertOperation s setOp

      convertOperation :: Set v -> (v, SetOperation) -> (Set v, [ListOperation v])
      convertOperation s (value, Insert) =
        if Set.member value s
          then (s, [])
          else
            let sNew = Set.insert value s
            -- findIndex is partial but should be safe in this context, as the value was just inserted
            in (sNew, [ObservableList.ListInsert (fromIntegral $ Set.findIndex value sNew) value])
      convertOperation s (value, Delete) =
        case Set.lookupIndex value s of
          Nothing -> (s, [])
          Just index -> (Set.deleteAt index s, [ObservableList.ListDelete (fromIntegral index)])


toObservableList :: (ToObservableSet l e v s, Ord v) => s -> ObservableList l e v
toObservableList x = ObservableList.ObservableList (ObservableT (ObservableSetToList (toObservableSet x)))


newtype ObservableListToSet canLoad exceptions v = ObservableListToSet (ObservableList canLoad exceptions v)

instance Ord v => IsObservableSet canLoad exceptions v (ObservableListToSet canLoad exceptions v) where

instance Ord v => IsObservableCore canLoad exceptions Set v (ObservableListToSet canLoad exceptions v) where
  isEmpty# (ObservableListToSet x) = isEmpty# x

  readObservable# (ObservableListToSet x) =
    mapObservableStateResult (Set.fromList . toList) <$> readObservable# x

  attachObserver# (ObservableListToSet (ObservableList.ObservableList x)) =
    attachDeltaRemappingObserver x (Set.fromList . toList) convertDelta
    where
      convertDelta :: Seq v -> Delta Seq v -> Maybe (ObservableUpdate Set v)
      convertDelta l delta =
        let
          (_finalList, setOps) =
            foldl' addOperation (mempty, mempty) $ ObservableList.deltaToOperations (fromIntegral $ Seq.length l) delta
        in if Map.null setOps
          then Nothing
          else Just (ObservableUpdateDelta (SetDelta setOps))

      addOperation :: (Seq v, Map v SetOperation) -> ListOperation v -> (Seq v, Map v SetOperation)
      addOperation (oldList, setOps) listOp =
        (ObservableList.applyListOperatonsToSeq oldList [listOp], convertOperation oldList listOp setOps)

      convertOperation :: Seq v -> ListOperation v -> Map v SetOperation -> Map v SetOperation
      convertOperation _l (ObservableList.ListInsert _ value) = Map.insert value Insert
      convertOperation _l (ObservableList.ListAppend value) = Map.insert value Insert
      convertOperation l (ObservableList.ListDelete index) = case Seq.lookup (fromIntegral index) l of
        Nothing -> id -- illegal delta
        Just value ->
          if value `elem` Seq.deleteAt (fromIntegral index) l
            then id -- still elements with same value in the list
            else Map.insert value Delete


fromObservableList :: (ObservableList.ToObservableList l e v s, Ord v) => s -> ObservableSet l e v
fromObservableList x = ObservableSet (ObservableT (ObservableListToSet (ObservableList.toObservableList x)))


-- * ObservableSetVar

newtype ObservableSetVar v = ObservableSetVar (Subject NoLoad '[] Set v)

deriving newtype instance Ord v => IsObservableCore NoLoad '[] Set v (ObservableSetVar v)
deriving newtype instance Ord v => IsObservableSet NoLoad '[] v (ObservableSetVar v)
deriving newtype instance Ord v => ToObservableT NoLoad '[] Set v (ObservableSetVar v)

instance Ord v => IsObservableSet l e v (Subject l e Set v)
  -- TODO

newVar :: MonadSTMc NoRetry '[] m => Set v -> m (ObservableSetVar v)
newVar x = liftSTMc @NoRetry @'[] $ ObservableSetVar <$> newSubject x

newVarIO :: MonadIO m => Set v -> m (ObservableSetVar v)
newVarIO x = liftIO $ ObservableSetVar <$> newSubjectIO x

readVar :: MonadSTMc NoRetry '[] m => ObservableSetVar v -> m (Set v)
readVar (ObservableSetVar subject) = readSubject subject

readVarIO :: MonadIO m => ObservableSetVar v -> m (Set v)
readVarIO (ObservableSetVar subject) = readSubjectIO subject

insertVar :: (Ord v, MonadSTMc NoRetry '[] m) => ObservableSetVar v -> v -> m ()
insertVar (ObservableSetVar var) value =
  changeSubject var (ObservableChangeLiveDelta (insertDelta value))

deleteVar :: (Ord v, MonadSTMc NoRetry '[] m) => ObservableSetVar v -> v -> m ()
deleteVar (ObservableSetVar var) value =
  changeSubject var (ObservableChangeLiveDelta (deleteDelta value))

replaceVar :: MonadSTMc NoRetry '[] m => ObservableSetVar v -> Set v -> m ()
replaceVar (ObservableSetVar var) new = replaceSubject var new

clearVar :: (Ord v, MonadSTMc NoRetry '[] m) => ObservableSetVar v -> m ()
clearVar var = replaceVar var mempty
