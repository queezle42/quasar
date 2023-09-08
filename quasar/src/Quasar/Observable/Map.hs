{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Map (
  -- * ObservableMap
  ObservableMap(..),
  ToObservableMap,
  toObservableMap,
  readObservableMap,
  IsObservableMap(..),
  query,

  -- ** Delta types
  ObservableMapDelta(..),
  ObservableMapOperation(..),

  -- * Observable interaction
  bindObservableMap,

  -- ** Const construction
  empty,
  singleton,
  fromList,

  -- ** Query
  lookup,
  count,
  isEmpty,

  -- ** Combine
  union,
  unionWith,
  unionWithKey,

  -- ** Traversal
  mapWithKey,
  mapSTM,
  attachForEach,

  -- ** Filter
  filter,
  filterWithKey,

  -- * ObservableMapVar
  ObservableMapVar,
  newObservableMapVar,
  newObservableMapVarIO,
  insert,
  delete,
  lookupDelete,
  replace,
  clear,

  -- * Reexports
  -- ** Observable
  CanLoad,
) where

import Control.Applicative hiding (empty)
import Control.Monad.Except
import Data.Binary (Binary)
import Data.Map.Merge.Strict qualified as Map
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Quasar.Observable.Core
import Quasar.Observable.List (ObservableList)
import Quasar.Observable.Subject
import Quasar.Observable.Traversable
import Quasar.Prelude hiding (filter, lookup)
import Quasar.Resources.Disposer


newtype ObservableMapDelta k v
  = ObservableMapDelta (Map k (ObservableMapOperation v))
  deriving Generic

instance (Binary k, Binary v) => Binary (ObservableMapDelta k v)

instance Functor (ObservableMapDelta k) where
  fmap f (ObservableMapDelta x) = ObservableMapDelta (f <<$>> x)

instance Foldable (ObservableMapDelta k) where
  foldMap f (ObservableMapDelta x) = foldMap (foldMap f) x

instance Traversable (ObservableMapDelta k) where
  traverse f (ObservableMapDelta ops) = ObservableMapDelta <$> traverse (traverse f) ops

data ObservableMapOperation v = ObservableMapInsert v | ObservableMapDelete
  deriving Generic

instance Binary v => Binary (ObservableMapOperation v)

instance Functor ObservableMapOperation where
  fmap f (ObservableMapInsert x) = ObservableMapInsert (f x)
  fmap _f ObservableMapDelete = ObservableMapDelete

instance Foldable ObservableMapOperation where
  foldMap f (ObservableMapInsert x) = f x
  foldMap _f ObservableMapDelete = mempty

instance Traversable ObservableMapOperation where
  traverse f (ObservableMapInsert x) = ObservableMapInsert <$> f x
  traverse _f ObservableMapDelete = pure ObservableMapDelete

insertDelta :: k -> v -> ObservableMapDelta k v
insertDelta key value = ObservableMapDelta (Map.singleton key (ObservableMapInsert value))

deleteDelta :: k -> ObservableMapDelta k v
deleteDelta key = ObservableMapDelta (Map.singleton key ObservableMapDelete)

observableMapOperationToMaybe :: ObservableMapOperation v -> Maybe v
observableMapOperationToMaybe (ObservableMapInsert x) = Just x
observableMapOperationToMaybe ObservableMapDelete = Nothing

applyObservableMapOperations :: Ord k => Map k (ObservableMapOperation v) -> Map k v -> Map k v
applyObservableMapOperations ops old =
  Map.merge
    Map.preserveMissing'
    (Map.mapMaybeMissing \_ -> observableMapOperationToMaybe)
    (Map.zipWithMaybeMatched \_ _ -> observableMapOperationToMaybe)
    old
    ops

instance Ord k => ObservableContainer (Map k) v where
  type ContainerConstraint canLoad exceptions (Map k) v a = IsObservableMap canLoad exceptions k v a
  type Delta (Map k) = (ObservableMapDelta k)
  applyDelta (ObservableMapDelta ops) old = applyObservableMapOperations ops old
  mergeDelta (ObservableMapDelta old) (ObservableMapDelta new) = ObservableMapDelta (Map.union new old)
  toDelta = fst
  contentFromEvaluatedDelta = snd

instance ContainerCount (Map k) where
  containerCount# x = fromIntegral (Map.size x)
  containerIsEmpty# x = Map.null x

instance Ord k => TraversableObservableContainer (Map k) where
  selectRemoved (ObservableMapDelta ops) old = mapMaybe (\key -> Map.lookup key old) (Map.keys ops)



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
  (Ord k, MonadSTMc NoRetry exceptions m) =>
  ObservableMap NoLoad exceptions k v ->
  m (Map k v)
readObservableMap (ObservableMap fx) = readObservableT fx

newtype ObservableMap canLoad exceptions k v = ObservableMap (ObservableT canLoad exceptions (Map k) v)

instance Ord k => ToObservableT canLoad exceptions (Map k) v (ObservableMap canLoad exceptions k v) where
  toObservableT (ObservableMap x) = x

instance IsObservableCore canLoad exceptions (Map k) v (ObservableMap canLoad exceptions k v) where
  readObservable# (ObservableMap (ObservableT x)) = readObservable# x
  attachObserver# (ObservableMap x) = attachObserver# x
  attachEvaluatedObserver# (ObservableMap x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableMap (ObservableT x)) = isCachedObservable# x

instance IsObservableMap canLoad exceptions k v (ObservableMap canLoad exceptions k v) where
  lookupKey# (ObservableMap x) = lookupKey# x
  lookupItem# (ObservableMap x) = lookupItem# x
  lookupValue# (ObservableMap x) = lookupValue# x

instance Ord k => Functor (ObservableMap canLoad exceptions k) where
  fmap fn (ObservableMap x) = ObservableMap (ObservableT (mapObservable# fn x))


query
  :: ToObservableMap canLoad exceptions k v a
  => a
  -> ObservableList canLoad exceptions (Bounds k)
  -> ObservableMap canLoad exceptions k v
query x = query# (toObservableMap x)



instance (Ord k, IsObservableCore l e (Map k) v b) => IsObservableMap l e k v (BindObservable l e va b) where
  -- TODO


bindObservableMap
  :: forall canLoad exceptions k v va. Ord k
  => Observable canLoad exceptions va
  -> (va -> ObservableMap canLoad exceptions k v)
  -> ObservableMap canLoad exceptions k v
bindObservableMap fx fn = ObservableMap (bindObservableT fx ((\(ObservableMap x) -> x) . fn))


constObservableMap :: ObservableState canLoad (ObservableResult exceptions (Map k)) v -> ObservableMap canLoad exceptions k v
constObservableMap = ObservableMap . ObservableT


empty :: ObservableMap canLoad exceptions k v
empty = constObservableMap (ObservableStateLiveOk Map.empty)

singleton :: k -> v -> ObservableMap canLoad exceptions k v
singleton key value = constObservableMap (ObservableStateLiveOk (Map.singleton key value))

lookup :: Ord k => k -> ObservableMap l e k v -> Observable l e (Maybe v)
lookup key x = lookupValue# (toObservableMap x) (Key key)

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
    mapObservableState (mapObservableResult (Map.mapWithKey fn)) <<$>> attachObserver# observable \change ->
      callback (mapObservableChange (mapObservableResult (Map.mapWithKey fn)) (mapDeltaWithKey fn) change)
    where
      mapDeltaWithKey :: (k -> va -> v) -> ObservableMapDelta k va -> ObservableMapDelta k v
      mapDeltaWithKey f (ObservableMapDelta ops) = ObservableMapDelta (Map.mapWithKey (mapOperationWithKey f) ops)
      mapOperationWithKey :: (k -> va -> v) -> k -> ObservableMapOperation va -> ObservableMapOperation v
      mapOperationWithKey f key (ObservableMapInsert x) = ObservableMapInsert (f key x)
      mapOperationWithKey _f _key ObservableMapDelete = ObservableMapDelete

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
      deltaFn f (ObservableUpdateDelta (ObservableMapDelta ops)) _prev other =
        Just (ObservableUpdateDelta (ObservableMapDelta (Map.fromList ((\(k, v) -> (k, helper k v)) <$> Map.toList ops))))
        where
          helper :: k -> ObservableMapOperation v -> ObservableMapOperation v
          helper key (ObservableMapInsert x) = ObservableMapInsert do
            maybe x (f key x) (Map.lookup key other)
          helper key ObservableMapDelete =
            maybe ObservableMapDelete ObservableMapInsert (Map.lookup key other)
      deltaFn f (ObservableUpdateReplace new) prev other =
        deltaFn f (ObservableUpdateDelta (ObservableMapDelta (Map.union (ObservableMapInsert <$> new) (ObservableMapDelete <$ prev)))) prev other

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
      ObservableChangeLiveUpdate (ObservableUpdateOk (ObservableUpdateReplace new)) ->
        callback (ObservableChangeLiveUpdate (ObservableUpdateOk (ObservableUpdateReplace (Map.filterWithKey fn new))))
      ObservableChangeLiveUpdate (ObservableUpdateOk (ObservableUpdateDelta delta)) ->
        callback (ObservableChangeLiveUpdate (ObservableUpdateOk (ObservableUpdateDelta (filterDelta delta))))
      -- Exception, loading, cleared or unchanged
      other -> callback other

    pure (disposer, mapObservableStateResult (Map.filterWithKey fn) initial)
    where
      filterDelta :: ObservableMapDelta k v -> ObservableMapDelta k v
      filterDelta (ObservableMapDelta ops) = ObservableMapDelta (Map.mapWithKey filterOperation ops)
      filterOperation :: k -> ObservableMapOperation v -> ObservableMapOperation v
      filterOperation key ins@(ObservableMapInsert value) =
        if fn key value then ins else ObservableMapDelete
      filterOperation _key ObservableMapDelete = ObservableMapDelete

instance IsObservableMap l e k v (FilteredObservableMap l e k v) where

filter :: (v -> Bool) -> ObservableMap l e k v -> ObservableMap l e k v
filter fn = filterWithKey (const fn)

filterWithKey :: (k -> v -> Bool) -> ObservableMap l e k v -> ObservableMap l e k v
filterWithKey fn fx = ObservableMap (ObservableT (FilteredObservableMap fn fx))


-- * ObservableMapVar

newtype ObservableMapVar k v = ObservableMapVar (Subject NoLoad '[] (Map k) v)

deriving newtype instance Ord k => IsObservableCore NoLoad '[] (Map k) v (ObservableMapVar k v)
deriving newtype instance Ord k => IsObservableMap NoLoad '[] k v (ObservableMapVar k v)
deriving newtype instance Ord k => ToObservableT NoLoad '[] (Map k) v (ObservableMapVar k v)

instance Ord k => IsObservableMap l e k v (Subject l e (Map k) v)
  -- TODO

newObservableMapVar :: MonadSTMc NoRetry '[] m => Map k v -> m (ObservableMapVar k v)
newObservableMapVar x = liftSTMc @NoRetry @'[] $ ObservableMapVar <$> newSubject x

newObservableMapVarIO :: MonadIO m => Map k v -> m (ObservableMapVar k v)
newObservableMapVarIO x = liftIO $ ObservableMapVar <$> newSubjectIO x

insert :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> v -> m ()
insert (ObservableMapVar var) key value =
  changeSubject var (ObservableChangeLiveUpdate (ObservableUpdateDelta (insertDelta key value)))

delete :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> m ()
delete (ObservableMapVar var) key =
  changeSubject var (ObservableChangeLiveUpdate (ObservableUpdateDelta (deleteDelta key)))

lookupDelete :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> k -> m (Maybe v)
lookupDelete (ObservableMapVar var) key = do
  r <- Map.lookup key <$> readSubject var
  when (isJust r) do
    changeSubject var (ObservableChangeLiveUpdate (ObservableUpdateDelta (deleteDelta key)))
  pure r

replace :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> Map k v -> m ()
replace (ObservableMapVar var) new =
  changeSubject var (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk new)))

clear :: (Ord k, MonadSTMc NoRetry '[] m) => ObservableMapVar k v -> m ()
clear (ObservableMapVar var) =
  changeSubject var (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk mempty)))


instance Ord k => IsObservableMap l e k v (TraversingObservable l e (Map k) v)

mapSTM ::
  Ord k =>
  (va -> STMc NoRetry '[] (TSimpleDisposer, v)) ->
  ObservableMap l e k va ->
  ObservableMap l e k v
mapSTM fn (ObservableMap fx) = ObservableMap (observableTMapSTM fn fx)

attachForEach ::
  Ord k =>
  (va -> STMc NoRetry '[] TSimpleDisposer) ->
  ObservableMap l e k va ->
  STMc NoRetry '[] TSimpleDisposer
attachForEach fn (ObservableMap fx) = observableTAttachForEach fn fx
