{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Map (
  -- * ObservableMap
  ObservableMap(..),
  ToObservableMap,
  toObservableMap,
  readObservableMap,
  liftObservableMap,
  IsObservableMap(..),
  query,
  share,

  -- ** Delta types
  MapDelta(..),
  MapOperation(..),

  -- * Observable interaction
  bindObservable,

  -- ** Const construction
  empty,
  singleton,
  fromList,
  constObservableMap,

  -- ** Query
  lookup,
  lookupMin,
  lookupMax,
  count,
  isEmpty,

  -- ** Combine
  union,
  unionWith,
  unionWithKey,

  -- ** Traversal
  mapWithKey,
  traverse,
  traverseWithKey,
  attachForEach,

  -- ** Conversions
  keys,
  values,
  items,

  -- ** Filter
  filter,
  filterKey,
  filterWithKey,
  mapMaybe,
  mapMaybeWithKey,

  -- * ObservableMapVar (mutable observable var)
  ObservableMapVar(..),
  newVar,
  newVarIO,
  readVar,
  readVarIO,
  insertVar,
  deleteVar,
  lookupDeleteVar,
  replaceVar,
  clearVar,

  -- * Reexports
  -- ** Observable
  LoadKind,
) where

import Control.Applicative hiding (empty)
import Data.Binary (Binary)
import Data.Foldable (foldl')
import Data.Map.Merge.Strict qualified as Map
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe qualified as Maybe
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Traversable qualified as Traversable
import GHC.Records (HasField (..))
import Quasar.Disposer
import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Observable.List (ObservableList(..), IsObservableList, ListOperation(..))
import Quasar.Observable.List qualified as ObservableList
import Quasar.Observable.Share
import Quasar.Observable.Subject
import Quasar.Observable.Traversable
import Quasar.Prelude hiding (filter, lookup, traverse)
import Quasar.Utils.Map qualified as MapUtils


newtype MapDelta k v
  = MapDelta (Map k (MapOperation v))
  deriving (Generic, Show, Eq, Ord)

instance (Binary k, Binary v) => Binary (MapDelta k v)

instance Functor (MapDelta k) where
  fmap f (MapDelta x) = MapDelta (f <<$>> x)

instance Foldable (MapDelta k) where
  foldMap f (MapDelta x) = foldMap (foldMap f) x

instance Traversable (MapDelta k) where
  traverse f (MapDelta ops) = MapDelta <$> Traversable.traverse (Traversable.traverse f) ops

data MapOperation v = Insert v | Delete
  deriving (Generic, Show, Eq, Ord)

instance Binary v => Binary (MapOperation v)

instance Functor MapOperation where
  fmap f (Insert x) = Insert (f x)
  fmap _f Delete = Delete

instance Foldable MapOperation where
  foldMap f (Insert x) = f x
  foldMap _f Delete = mempty

instance Traversable MapOperation where
  traverse f (Insert x) = Insert <$> f x
  traverse _f Delete = pure Delete

insertDelta :: k -> v -> MapDelta k v
insertDelta key value = MapDelta (Map.singleton key (Insert value))

deleteDelta :: k -> MapDelta k v
deleteDelta key = MapDelta (Map.singleton key Delete)

instance HasField "maybe" (MapOperation v) (Maybe v) where
  getField (Insert x) = Just x
  getField Delete = Nothing

applyOperations :: Ord k => Map k (MapOperation v) -> Map k v -> Map k v
applyOperations ops old =
  Map.merge
    Map.preserveMissing'
    (Map.mapMaybeMissing \_ op -> op.maybe)
    (Map.zipWithMaybeMatched \_ _ op -> op.maybe)
    old
    ops

instance Ord k => ObservableContainer (Map k) v where
  type ContainerConstraint canLoad exceptions (Map k) v a = IsObservableMap canLoad exceptions k v a
  type Delta (Map k) = (MapDelta k)
  applyDelta (MapDelta ops) old = Just (applyOperations ops old)
  mergeDelta (MapDelta old) (MapDelta new) = MapDelta (Map.union new old)

instance ContainerCount (Map k) where
  containerCount# x = fromIntegral (Map.size x)
  containerIsEmpty# x = Map.null x

instance Ord k => TraversableObservableContainer (Map k) where
  selectRemoved (MapDelta ops) old = Maybe.mapMaybe (\key -> Map.lookup key old) (Map.keys ops)



class IsObservableCore canLoad exceptions (Map k) v a => IsObservableMap canLoad exceptions k v a where
  lookupKey# :: Ord k => a -> Selector k -> Observable canLoad exceptions (Maybe k)
  lookupKey# = undefined

  lookupItem# :: Ord k => a -> Selector k -> Observable canLoad exceptions (Maybe (k, v))
  lookupItem# = undefined

  lookupValue# :: Ord k => a -> Selector k -> Observable canLoad exceptions (Maybe v)
  lookupValue# x selector = snd <<$>> lookupItem# x selector

  query# :: a -> ObservableList canLoad exceptions (Bounds k) -> ObservableMap canLoad exceptions k v
  query# = undefined


instance IsObservableMap canLoad exceptions k v (ObservableState canLoad (ObservableResult exceptions (Map k)) v) where

instance Ord k => IsObservableMap canLoad exceptions k v (ObservableT canLoad exceptions (Map k) v) where


instance Ord k => IsObservableMap canLoad exceptions k v (MappedObservable canLoad exceptions (Map k) v) where



type ToObservableMap canLoad exceptions k v a = ToObservableT canLoad exceptions (Map k) v a

toObservableMap :: ToObservableMap canLoad exceptions k v a => a -> ObservableMap canLoad exceptions k v
toObservableMap x = ObservableMap (toObservableT x)

readObservableMap ::
  forall exceptions k v m a.
  (MonadSTMc NoRetry exceptions m) =>
  ObservableMap NoLoad exceptions k v ->
  m (Map k v)
readObservableMap (ObservableMap fx) = readObservableT fx

newtype ObservableMap canLoad exceptions k v = ObservableMap (ObservableT canLoad exceptions (Map k) v)

instance ToObservableT canLoad exceptions (Map k) v (ObservableMap canLoad exceptions k v) where
  toObservableT (ObservableMap x) = x

instance IsObservableCore canLoad exceptions (Map k) v (ObservableMap canLoad exceptions k v) where
  readObservable# (ObservableMap (ObservableT x)) = readObservable# x
  attachObserver# (ObservableMap x) = attachObserver# x
  attachEvaluatedObserver# (ObservableMap x) = attachEvaluatedObserver# x
  isSharedObservable# (ObservableMap (ObservableT x)) = isSharedObservable# x

instance IsObservableMap canLoad exceptions k v (ObservableMap canLoad exceptions k v) where
  lookupKey# (ObservableMap x) = lookupKey# x
  lookupItem# (ObservableMap x) = lookupItem# x
  lookupValue# (ObservableMap x) = lookupValue# x

instance Ord k => Functor (ObservableMap canLoad exceptions k) where
  fmap fn (ObservableMap x) = ObservableMap (ObservableT (mapObservable# fn x))

-- | `(<>)` is equivalent `union`, which is left-biased.
instance Ord k => Semigroup (ObservableMap canLoad exceptions k v) where
  (<>) = union

instance Ord k => Monoid (ObservableMap canLoad exceptions k v) where
  mempty = empty



query
  :: ToObservableMap canLoad exceptions k v a
  => a
  -> ObservableList canLoad exceptions (Bounds k)
  -> ObservableMap canLoad exceptions k v
query x = query# (toObservableMap x)



instance Ord k => IsObservableMap canLoad exceptions k v (SharedObservable canLoad exceptions (Map k) v) where
  -- TODO

share ::
  (Ord k, MonadSTMc NoRetry '[] m) =>
  ObservableMap canLoad exceptions k v ->
  m (ObservableMap canLoad exceptions k v)
share (ObservableMap f) = ObservableMap <$> shareObservableT f



instance (Ord k, IsObservableCore l e (Map k) v b) => IsObservableMap l e k v (BindObservable l e ea va b) where
  -- TODO


bindObservable ::
  forall canLoad exceptions k v va. Ord k =>
  Observable canLoad exceptions va ->
  (va -> ObservableMap canLoad exceptions k v) ->
  ObservableMap canLoad exceptions k v
bindObservable fx fn = ObservableMap (bindObservableT fx ((\(ObservableMap x) -> x) . fn))


constObservableMap :: ObservableState canLoad (ObservableResult exceptions (Map k)) v -> ObservableMap canLoad exceptions k v
constObservableMap = ObservableMap . ObservableT



instance (ea :<< e, RelaxLoad la l, Ord k) => IsObservableMap l e k v (LiftedObservable l e la ea (Map k) v) where
  -- TODO

liftObservableMap ::
  forall la ea l e k v.
  (ea :<< e, RelaxLoad la l, Ord k) =>
  ObservableMap la ea k v -> ObservableMap l e k v
liftObservableMap (ObservableMap fx) = ObservableMap (liftObservableT fx)


empty :: ObservableMap canLoad exceptions k v
empty = constObservableMap (ObservableStateLiveOk Map.empty)

singleton :: k -> v -> ObservableMap canLoad exceptions k v
singleton key value = constObservableMap (ObservableStateLiveOk (Map.singleton key value))

lookup :: Ord k => k -> ObservableMap l e k v -> Observable l e (Maybe v)
lookup key x = lookupValue# (toObservableMap x) (Key key)

lookupMin :: Ord k => ObservableMap l e k v -> Observable l e (Maybe v)
lookupMin x = lookupValue# (toObservableMap x) Min

lookupMax :: Ord k => ObservableMap l e k v -> Observable l e (Maybe v)
lookupMax x = lookupValue# (toObservableMap x) Max

count :: Ord k => ObservableMap l e k v -> Observable l e Int64
count = count#

isEmpty :: Ord k => ObservableMap l e k v -> Observable l e Bool
isEmpty = isEmpty#

-- | From unordered list.
fromList :: Ord k => [(k, v)] -> ObservableMap l e k v
fromList list = constObservableMap (ObservableStateLiveOk (Map.fromList list))


data MappedObservableMap canLoad exceptions k va v = MappedObservableMap (k -> va -> v) (ObservableMap canLoad exceptions k va)

instance ObservableFunctor (Map k) => IsObservableCore canLoad exceptions (Map k) v (MappedObservableMap canLoad exceptions k va v) where
  readObservable# (MappedObservableMap fn observable) =
    mapObservableStateResult (Map.mapWithKey fn) <$> readObservable# observable

  attachObserver# (MappedObservableMap fn observable) callback =
    mapObservableStateResult (Map.mapWithKey fn) <<$>> attachObserver# observable \change ->
      callback (mapObservableChangeResult (Map.mapWithKey fn) (mapDeltaWithKey fn) change)
    where
      mapDeltaWithKey :: (k -> va -> v) -> MapDelta k va -> MapDelta k v
      mapDeltaWithKey f (MapDelta ops) = MapDelta (Map.mapWithKey (mapOperationWithKey f) ops)
      mapOperationWithKey :: (k -> va -> v) -> k -> MapOperation va -> MapOperation v
      mapOperationWithKey f key (Insert x) = Insert (f key x)
      mapOperationWithKey _f _key Delete = Delete

  count# (MappedObservableMap _ upstream) = count# upstream
  isEmpty# (MappedObservableMap _ upstream) = isEmpty# upstream

instance ObservableFunctor (Map k) => IsObservableMap canLoad exceptions k v (MappedObservableMap canLoad exceptions k va v) where
  lookupKey# (MappedObservableMap _ upstream) sel = lookupKey# upstream sel
  lookupItem# (MappedObservableMap fn upstream) sel =
    (\(key, value) -> (key, fn key value)) <<$>> lookupItem# upstream sel
  lookupValue# (MappedObservableMap fn upstream) sel@(Key key) =
    fn key <<$>> lookupValue# upstream sel
  lookupValue# (MappedObservableMap fn upstream) sel =
    uncurry fn <<$>> lookupItem# upstream sel

mapWithKey :: Ord k => (k -> va -> v) -> ObservableMap canLoad exceptions k va -> ObservableMap canLoad exceptions k v
mapWithKey fn x = ObservableMap (ObservableT (MappedObservableMap fn x))


data ObservableMapUnionWith l e k v =
  ObservableMapUnionWith
    (k -> v -> v -> v)
    (ObservableMap l e k v)
    (ObservableMap l e k v)

instance Ord k => IsObservableCore canLoad exceptions (Map k) v (ObservableMapUnionWith canLoad exceptions k v) where
  readObservable# (ObservableMapUnionWith fn fx fy) = do
    readObservable# fx >>= \case
      ObservableStateLoading -> pure ObservableStateLoading
      (ObservableStateLive (ObservableResultEx ex)) -> pure (ObservableStateLive (ObservableResultEx ex))
      (ObservableStateLive (ObservableResultOk x)) -> do
        y <- readObservable# fy
        pure (mapObservableStateResult (Map.unionWithKey fn x) y)

  attachObserver# (ObservableMapUnionWith fn fx fy) =
    attachMonoidMergeObserver fullMergeFn (deltaFn fn) (deltaFn (flip <$> fn)) fx fy
    where
      fullMergeFn :: Map k v -> Map k v -> Map k v
      fullMergeFn = Map.unionWithKey fn
      deltaFn :: (k -> v -> v -> v) -> ObservableUpdate (Map k) v -> Map k v -> Map k v -> Maybe (ObservableUpdate (Map k) v)
      deltaFn f (ObservableUpdateDelta (MapDelta ops)) _prev other =
        Just (ObservableUpdateDelta (MapDelta (Map.fromList ((\(k, v) -> (k, helper k v)) <$> Map.toList ops))))
        where
          helper :: k -> MapOperation v -> MapOperation v
          helper key (Insert x) = Insert do
            maybe x (f key x) (Map.lookup key other)
          helper key Delete =
            maybe Delete Insert (Map.lookup key other)
      deltaFn f (ObservableUpdateReplace new) prev other =
        deltaFn f (ObservableUpdateDelta (MapDelta (Map.union (Insert <$> new) (Delete <$ prev)))) prev other

  isEmpty# (ObservableMapUnionWith _ x y) = liftA2 (||) (isEmpty# x) (isEmpty# y)

instance Ord k => IsObservableMap canLoad exceptions k v (ObservableMapUnionWith canLoad exceptions k v) where
  lookupKey# (ObservableMapUnionWith _fn fx fy) sel = do
    x <- lookupKey# fx sel
    y <- lookupKey# fy sel
    pure (liftA2 (merge sel) x y)
    where
      merge :: Selector k -> k -> k -> k
      merge Min = min
      merge Max = max
      merge (Key _) = const
  lookupItem# (ObservableMapUnionWith fn fx fy) sel@(Key key) = do
    mx <- lookupValue# fx sel
    my <- lookupValue# fy sel
    pure (liftA2 (\x y -> (key, fn key x y)) mx my)
  lookupItem# (ObservableMapUnionWith fn fx fy) sel = do
    x <- lookupItem# fx sel
    y <- lookupItem# fy sel
    pure (liftA2 (merge sel) x y)
    where
      merge :: Selector k -> (k, v) -> (k, v) -> (k, v)
      merge Min x@(kx, _) y@(ky, _) = if kx <= ky then x else y
      merge Max x@(kx, _) y@(ky, _) = if kx >= ky then x else y
      merge (Key key) (_, x) (_, y) = (key, fn key x y)


unionWithKey :: Ord k => (k -> v -> v -> v) -> ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
unionWithKey fn x y = ObservableMap (ObservableT (ObservableMapUnionWith fn x y))

unionWith :: Ord k => (v -> v -> v) -> ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
unionWith fn = unionWithKey \_ x y -> fn x y

-- | The left-biased union of two observable maps. The first map is preferred when duplicate keys are encountered.
union :: Ord k => ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
-- TODO write union variant that only sends updates when needed (i.e. no update for a RHS change when the LHS has a value for that key)
union = unionWithKey \_ x _ -> x


-- * Filter

data FilteredObservableMap l e k v = FilteredObservableMap (k -> v -> Bool) (ObservableMap l e k v)

instance IsObservableCore l e (Map k) v (FilteredObservableMap l e k v) where
  readObservable# (FilteredObservableMap fn fx) =
    mapObservableStateResult (Map.filterWithKey fn) <$> readObservable# fx

  attachObserver# (FilteredObservableMap fn fx) callback = do
    (disposer, initial) <- attachObserver# fx \case
      ObservableChangeLiveReplace (ObservableResultOk new) ->
        callback (ObservableChangeLiveReplace (ObservableResultOk (Map.filterWithKey fn new)))
      ObservableChangeLiveDelta delta ->
        callback (ObservableChangeLiveDelta (filterDelta delta))
      -- Exception, loading, cleared or unchanged
      other -> callback other

    pure (disposer, mapObservableStateResult (Map.filterWithKey fn) initial)
    where
      filterDelta :: MapDelta k v -> MapDelta k v
      filterDelta (MapDelta ops) = MapDelta (Map.mapWithKey filterOperation ops)
      filterOperation :: k -> MapOperation v -> MapOperation v
      filterOperation key ins@(Insert value) =
        if fn key value then ins else Delete
      filterOperation _key Delete = Delete

instance IsObservableMap l e k v (FilteredObservableMap l e k v) where

filter :: (v -> Bool) -> ObservableMap l e k v -> ObservableMap l e k v
filter fn = filterWithKey (const fn)

filterWithKey :: (k -> v -> Bool) -> ObservableMap l e k v -> ObservableMap l e k v
filterWithKey fn fx = ObservableMap (ObservableT (FilteredObservableMap fn fx))

-- | Note: Implemented using `filterWithKey`.
filterKey :: (k -> Bool) -> ObservableMap l e k v -> ObservableMap l e k v
filterKey fn fx = filterWithKey (\key _ -> fn key) fx


data MapMaybeObservableMap l e k va v = MapMaybeObservableMap (k -> va -> Maybe v) (ObservableMap l e k va)

instance Ord k => IsObservableCore l e (Map k) v (MapMaybeObservableMap l e k va v) where
  readObservable# (MapMaybeObservableMap fn fx) =
    mapObservableStateResult (Map.mapMaybeWithKey fn) <$> readObservable# fx

  attachObserver# (MapMaybeObservableMap fn fx) callback = do
    (disposer, initial) <- attachObserver# fx \change -> callback case change of
      ObservableChangeLiveReplace (ObservableResultOk new) ->
        ObservableChangeLiveReplace (ObservableResultOk (Map.mapMaybeWithKey fn new))
      ObservableChangeLiveDelta delta ->
        ObservableChangeLiveDelta (filterDelta delta)
      -- Exception, loading, cleared or unchanged
      -- Values are passed through unchanged but are reconstructed because the type changes.
      ObservableChangeLiveReplace (ObservableResultEx ex) ->
        ObservableChangeLiveReplace (ObservableResultEx ex)
      ObservableChangeLoadingClear -> ObservableChangeLoadingClear
      ObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      ObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged

    pure (disposer, mapObservableStateResult (Map.mapMaybeWithKey fn) initial)
    where
      filterDelta :: MapDelta k va -> MapDelta k v
      filterDelta (MapDelta ops) = MapDelta (Map.mapWithKey filterOperation ops)
      filterOperation :: k -> MapOperation va -> MapOperation v
      filterOperation key (Insert value) = maybe Delete Insert (fn key value)
      filterOperation _key Delete = Delete

instance Ord k => IsObservableMap l e k v (MapMaybeObservableMap l e k va v) where

mapMaybe :: Ord k => (va -> Maybe v) -> ObservableMap l e k va -> ObservableMap l e k v
mapMaybe fn = mapMaybeWithKey (const fn)

mapMaybeWithKey ::
  Ord k =>
  (k -> va -> Maybe v) -> ObservableMap l e k va -> ObservableMap l e k v
mapMaybeWithKey fn fx = ObservableMap (ObservableT (MapMaybeObservableMap fn fx))


-- * Convert to list of values/items

newtype ObservableMapValues canLoad exceptions k v = ObservableMapValues (ObservableMap canLoad exceptions k v)

instance Ord k => IsObservableList canLoad exceptions v (ObservableMapValues canLoad exceptions k v) where

instance Ord k => IsObservableCore canLoad exceptions Seq v (ObservableMapValues canLoad exceptions k v) where
  isEmpty# (ObservableMapValues x) = isEmpty# x

  count# (ObservableMapValues x) = count# x

  readObservable# (ObservableMapValues x) =
    mapObservableStateResult (Seq.fromList . Map.elems) <$> readObservable# x

  attachObserver# (ObservableMapValues (ObservableMap x)) =
    attachDeltaRemappingObserver x (Seq.fromList . Map.elems) convertDelta
    where
      convertDelta :: Map k v -> MapDelta k v -> Maybe (ObservableUpdate Seq v)
      convertDelta m (MapDelta ops) =
        let (_finalMap, listOps) = foldl' addOperation (m, []) (Map.toList ops)
        in ObservableList.operationsToUpdate (fromIntegral (Map.size m)) listOps

      addOperation :: (Map k v, [ListOperation v]) -> (k, MapOperation v) -> (Map k v, [ListOperation v])
      addOperation (m, listOps) mapOp = (listOps <>) <$> convertOperation m mapOp

      convertOperation :: Map k v -> (k, MapOperation v) -> (Map k v, [ListOperation v])
      convertOperation m (key, Insert value) =
        let (replaced, newMap) = MapUtils.insertCheckReplace key value m
        in case fromIntegral <$> Map.lookupIndex key newMap of
          Nothing -> unreachableCodePath
          Just index -> (newMap,) if replaced
            then [ListDelete index, ListInsert index value]
            else [ListInsert index value]
      convertOperation m (key, Delete) =
        let i = maybeToList (Map.lookupIndex key m)
        in (Map.delete key m, ListDelete . fromIntegral <$> i)

values :: Ord k => ObservableMap canLoad exceptions k v -> ObservableList canLoad exceptions v
values x = ObservableList (ObservableT (ObservableMapValues (toObservableMap x)))

items :: Ord k => ObservableMap canLoad exceptions k v -> ObservableList canLoad exceptions (k, v)
items x = values $ mapWithKey (,) x

keys :: Ord k => ObservableMap canLoad exceptions k v -> ObservableList canLoad exceptions k
keys x = values $ mapWithKey const x


-- * ObservableMapVar

newtype ObservableMapVar k v = ObservableMapVar (Subject NoLoad '[] (Map k) v)

deriving newtype instance Ord k => IsObservableCore NoLoad '[] (Map k) v (ObservableMapVar k v)
deriving newtype instance Ord k => IsObservableMap NoLoad '[] k v (ObservableMapVar k v)
deriving newtype instance Ord k => ToObservableT NoLoad '[] (Map k) v (ObservableMapVar k v)

instance Ord k => IsObservableMap l e k v (Subject l e (Map k) v)
  -- TODO

newVar :: MonadSTMc NoRetry '[] m => Map k v -> m (ObservableMapVar k v)
newVar x = liftSTMc @NoRetry @'[] $ ObservableMapVar <$> newSubject x

newVarIO :: MonadIO m => Map k v -> m (ObservableMapVar k v)
newVarIO x = liftIO $ ObservableMapVar <$> newSubjectIO x

readVar :: MonadSTMc NoRetry '[] m => ObservableMapVar k v -> m (Map k v)
readVar (ObservableMapVar subject) = readSubject subject

readVarIO :: MonadIO m => ObservableMapVar k v -> m (Map k v)
readVarIO (ObservableMapVar subject) = readSubjectIO subject

insertVar :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> v -> m ()
insertVar (ObservableMapVar var) key value =
  changeSubject var (ObservableChangeLiveDelta (insertDelta key value))

deleteVar :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> m ()
deleteVar (ObservableMapVar var) key =
  changeSubject var (ObservableChangeLiveDelta (deleteDelta key))

lookupDeleteVar :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> m (Maybe v)
lookupDeleteVar (ObservableMapVar var) key = do
  r <- Map.lookup key <$> readSubject var
  when (isJust r) do
    changeSubject var (ObservableChangeLiveDelta (deleteDelta key))
  pure r

replaceVar :: (MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> Map k v -> m ()
replaceVar (ObservableMapVar var) new = replaceSubject var new

clearVar :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> m ()
clearVar var = replaceVar var mempty


-- * Traversal

instance Ord k => IsObservableMap l e k v (TraversingObservable l e (Map k) v)

traverse ::
  Ord k =>
  (va -> STMc NoRetry '[] v) ->
  (v -> STMc NoRetry '[] ()) ->
  ObservableMap l e k va ->
  ObservableMap l e k v
traverse addFn removeFn (ObservableMap fx) =
  ObservableMap (traverseObservableT addFn removeFn fx)

traverseWithKey ::
  Ord k =>
  (k -> va -> STMc NoRetry '[] v) ->
  (k -> v -> STMc NoRetry '[] ()) ->
  ObservableMap l e k va ->
  ObservableMap l e k v
traverseWithKey addFn removeFn fx =
  snd <$> traverse (\(k, v) -> (k,) <$> addFn k v) (uncurry removeFn) (mapWithKey (,) fx)

attachForEach ::
  Ord k =>
  (va -> STMc NoRetry '[] v) ->
  (v -> STMc NoRetry '[] ()) ->
  ObservableMap l e k va ->
  STMc NoRetry '[] TDisposer
attachForEach addFn removeFn (ObservableMap fx) =
  attachForEachObservableT addFn removeFn fx
