module Quasar.Observable.ObservableMap (
  -- * ObservableMap interface
  ToObservableMap(..),
  attachMapDeltaObserver,
  IsObservableMap(..),
  ObservableMap,
  mapWithKey,
  lookup,
  isEmpty,
  length,
  values,
  items,

  empty,
  singleton,
  fromList,

  filter,
  filterWithKey,
  union,
  unionWith,
  unionWithKey,

  lookupMin,
  lookupMax,

  -- ** Deltas
  ObservableMapDelta(..),
  ObservableMapOperation(..),
  singletonDelta,
  packDelta,

  -- * Mutable ObservableMapVar container
  ObservableMapVar,
  newObservableMapVar,
  newObservableMapVarIO,
  insert,
  delete,
  lookupDelete,
) where

import Data.Foldable (find)
import Data.Foldable qualified as Foldable
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Quasar.Observable
import Quasar.Observable.ObservableList (ObservableList, IsObservableList, ToObservableList(..), ObservableListDelta(..))
import Quasar.Observable.ObservableList qualified as ObservableList
import Quasar.Prelude hiding (filter, length, lookup)
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix
import Quasar.Utils.Map qualified as Map
import Data.Functor ((<&>))


class ToObservable (Map k v) a => ToObservableMap k v a where
  toObservableMap :: a -> ObservableMap k v
  default toObservableMap :: IsObservableMap k v a => a -> ObservableMap k v
  toObservableMap = ObservableMap

class ToObservableMap k v a => IsObservableMap k v a where
  observeIsEmpty# :: a -> Observable Bool

  observeLength# :: a -> Observable Int

  observeKey# :: Ord k => k -> a -> Observable (Maybe v)

  -- | Register a listener to observe changes to the whole map. The callback
  -- will be invoked with the current state of the map immediately after
  -- registering and after that will be invoked for every change to the map.
  attachMapDeltaObserver# :: a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Map k v)

isEmpty :: ToObservableMap k v a => a -> Observable Bool
isEmpty x = observeIsEmpty# (toObservableMap x)

length :: ToObservableMap k v a => a -> Observable Int
length x = observeLength# (toObservableMap x)

lookup :: (ToObservableMap k v a, Ord k) => k -> a -> Observable (Maybe v)
lookup key x = observeKey# key (toObservableMap x)

attachMapDeltaObserver :: (ToObservableMap k v a, MonadSTMc NoRetry '[] m) => a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Map k v)
attachMapDeltaObserver x callback = liftSTMc $ attachMapDeltaObserver# (toObservableMap x) callback

data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance ToObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance ToObservableMap k v (ObservableMap k v) where
  toObservableMap = id

instance IsObservableMap k v (ObservableMap k v) where
  observeIsEmpty# (ObservableMap x) = observeIsEmpty# x
  observeLength# (ObservableMap x) = observeLength# x
  observeKey# key (ObservableMap x) = observeKey# key x
  attachMapDeltaObserver# (ObservableMap x) = attachMapDeltaObserver# x

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap (const f) x)

instance Ord k => Semigroup (ObservableMap k v) where
  (<>) = union

instance Ord k => Monoid (ObservableMap k v) where
  mempty = toObservableMap (ConstObservableMap mempty)


-- | A single operation that can be applied to an `ObservableMap`. Part of a
-- `ObservableMapDelta`.
--
-- Applying `Delete` to a non-existing key is a no-op.
data ObservableMapOperation k v = Insert k v | Delete k | DeleteAll

instance Functor (ObservableMapOperation k) where
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ DeleteAll = DeleteAll


-- | A list of operations that is applied atomically to an `ObservableMap`.
newtype ObservableMapDelta k v = ObservableMapDelta (Seq (ObservableMapOperation k v))

instance Functor (ObservableMapDelta k) where
  fmap f (ObservableMapDelta ops) = ObservableMapDelta (f <<$>> ops)

instance Eq k => Semigroup (ObservableMapDelta k v) where
  ObservableMapDelta x <> ObservableMapDelta y = ObservableMapDelta (go x y)
    where
      go :: Seq (ObservableMapOperation k v) -> Seq (ObservableMapOperation k v) -> Seq (ObservableMapOperation k v)
      go _ ys@(DeleteAll :<| _) = ys
      go (xs :|> Insert key1 _) ys@(Delete key2 :<| _) | key1 == key2 = go xs ys
      go (xs :|> Delete key1) ys@(Delete key2 :<| _) | key1 == key2 = go xs ys
      go xs ys = xs <> ys

instance Eq k => Monoid (ObservableMapDelta k v) where
  mempty = ObservableMapDelta mempty

singletonDelta :: ObservableMapOperation k v -> ObservableMapDelta k v
singletonDelta x = ObservableMapDelta (Seq.singleton x)

packDelta :: (Eq k, Foldable t) => t (ObservableMapOperation k v) -> ObservableMapDelta k v
packDelta x =
  -- The list is passed through the semigroup instance so duplicate updates are
  -- filtered.
  mconcat $ singletonDelta <$> toList x


empty :: ObservableMap k v
empty = ObservableMap (ConstObservableMap Map.empty)

singleton :: k -> v -> ObservableMap k v
singleton k v = ObservableMap (ConstObservableMap (Map.singleton k v))

fromList :: Ord k => [(k, v)] -> ObservableMap k v
fromList = ObservableMap . ConstObservableMap . Map.fromList

newtype ConstObservableMap k v = ConstObservableMap (Map k v)

instance ToObservable (Map k v) (ConstObservableMap k v) where
  toObservable (ConstObservableMap x) = pure x

instance ToObservableMap k v (ConstObservableMap k v)
instance IsObservableMap k v (ConstObservableMap k v) where
  observeIsEmpty# (ConstObservableMap x) = pure (null x)
  observeLength# (ConstObservableMap x) = pure (Foldable.length x)
  observeKey# key (ConstObservableMap x) = pure (Map.lookup key x)
  attachMapDeltaObserver# (ConstObservableMap x) _callback = pure (mempty, x)


data MappedObservableMap k v = forall a. MappedObservableMap (k -> a -> v) (ObservableMap k a)

instance ToObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = Map.mapWithKey fn <$> toObservable observable

instance ToObservableMap k v (MappedObservableMap k v)

instance IsObservableMap k v (MappedObservableMap k v) where
  observeIsEmpty# (MappedObservableMap _ observable) = observeIsEmpty# observable
  observeLength# (MappedObservableMap _ observable) = observeLength# observable
  observeKey# key (MappedObservableMap fn observable) = fn key <<$>> observeKey# key observable
  attachMapDeltaObserver# (MappedObservableMap fn observable) callback =
    Map.mapWithKey fn <<$>> attachMapDeltaObserver# observable \update -> callback (mapDeltaWithKey update)
    where
      mapDeltaWithKey (ObservableMapDelta ops) = ObservableMapDelta (mapUpdateWithKey <$> ops)
      mapUpdateWithKey (Insert k v) = Insert k (fn k v)
      mapUpdateWithKey (Delete k) = Delete k
      mapUpdateWithKey DeleteAll = DeleteAll

mapWithKey :: ToObservableMap k v1 a => (k -> v1 -> v2) -> a -> ObservableMap k v2
mapWithKey f x = ObservableMap (MappedObservableMap f (toObservableMap x))


data ObservableMapVar k v = ObservableMapVar {
  content :: TVar (Map k v),
  observers :: CallbackRegistry (Map k v),
  deltaObservers :: CallbackRegistry (ObservableMapDelta k v),
  keyObservers :: TVar (Map k (CallbackRegistry (Maybe v)))
}

instance ToObservable (Map k v) (ObservableMapVar k v)

instance IsObservable (Map k v) (ObservableMapVar k v) where
  readObservable# ObservableMapVar{content} = readTVar content
  attachObserver# ObservableMapVar{content, observers} callback = do
    disposer <- registerCallback observers callback
    value <- readTVar content
    pure (disposer, value)

instance ToObservableMap k v (ObservableMapVar k v)

instance IsObservableMap k v (ObservableMapVar k v) where
  observeIsEmpty# x = deduplicateObservable (Map.null <$> toObservable x)
  observeLength# x = deduplicateObservable (Foldable.length <$> toObservable x)
  observeKey# key x = toObservable (ObservableMapVarKeyObservable key x)
  attachMapDeltaObserver# ObservableMapVar{content, deltaObservers} callback = do
    disposer <- registerCallback deltaObservers callback
    initial <- readTVar content
    pure (disposer, initial)


data ObservableMapVarKeyObservable k v = ObservableMapVarKeyObservable k (ObservableMapVar k v)

instance Ord k => ToObservable (Maybe v) (ObservableMapVarKeyObservable k v)

instance Ord k => IsObservable (Maybe v) (ObservableMapVarKeyObservable k v) where
  attachObserver# (ObservableMapVarKeyObservable key ObservableMapVar{content, keyObservers}) callback = do
    value <- Map.lookup key <$> readTVar content
    registry <- do
      ko <- readTVar keyObservers
      case Map.lookup key ko of
        Just registry -> pure registry
        Nothing -> do
          registry <- newCallbackRegistryWithEmptyCallback (modifyTVar keyObservers (Map.delete key))
          modifyTVar keyObservers (Map.insert key registry)
          pure registry
    disposer <- registerCallback registry callback
    pure (disposer, value)

  readObservable# (ObservableMapVarKeyObservable key ObservableMapVar{content}) =
    Map.lookup key <$> readTVar content

newObservableMapVar :: MonadSTMc NoRetry '[] m => m (ObservableMapVar k v)
newObservableMapVar = liftSTMc @NoRetry @'[] do
  content <- newTVar Map.empty
  observers <- newCallbackRegistry
  deltaObservers <- newCallbackRegistry
  keyObservers <- newTVar Map.empty
  pure ObservableMapVar {content, observers, deltaObservers, keyObservers}

newObservableMapVarIO :: MonadIO m => m (ObservableMapVar k v)
newObservableMapVarIO = liftIO do
  content <- newTVarIO Map.empty
  observers <- newCallbackRegistryIO
  deltaObservers <- newCallbackRegistryIO
  keyObservers <- newTVarIO Map.empty
  pure ObservableMapVar {content, observers, deltaObservers, keyObservers}

insert :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> v -> ObservableMapVar k v -> m ()
insert key value ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.insert key value)
  callCallbacks observers state
  callCallbacks deltaObservers (singletonDelta (Insert key value))
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry (Just value)

delete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m ()
delete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.delete key)
  callCallbacks observers state
  callCallbacks deltaObservers (singletonDelta (Delete key))
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry Nothing

lookupDelete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m (Maybe v)
lookupDelete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  (result, newMap) <- stateTVar content \orig ->
    let (result, newMap) = Map.lookupDelete key orig
    in ((result, newMap), newMap)
  callCallbacks observers newMap
  callCallbacks deltaObservers (singletonDelta (Delete key))
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry Nothing
  pure result

data FilteredObservableMap k v = FilteredObservableMap (k -> v -> Bool) (ObservableMap k v)

instance ToObservable (Map k v) (FilteredObservableMap k v) where
  toObservable (FilteredObservableMap predicate upstream) =
    mapObservable (Map.filterWithKey predicate) upstream

instance ToObservableMap k v (FilteredObservableMap k v)

instance IsObservableMap k v (FilteredObservableMap k v) where
  observeIsEmpty# x =
    -- NOTE memory footprint could be improved by only tracking the keys (e.g. an (ObservableSet k))
    deduplicateObservable (Map.null <$> toObservable x)

  observeLength# x =
    -- NOTE memory footprint could be improved by only tracking the keys (e.g. an (ObservableSet k))
    deduplicateObservable (Foldable.length <$> toObservable x)

  observeKey# key (FilteredObservableMap predicate upstream) =
    find (predicate key) <$> observeKey# key upstream

  attachMapDeltaObserver# (FilteredObservableMap predicate upstream) callback =
    Map.filterWithKey predicate <<$>> attachMapDeltaObserver# upstream \delta -> callback (filterDelta delta)
    where
      filterDelta :: ObservableMapDelta k v -> ObservableMapDelta k v
      filterDelta (ObservableMapDelta ops) = ObservableMapDelta (filterOperation <$> ops)
      filterOperation :: ObservableMapOperation k v -> ObservableMapOperation k v
      filterOperation (Insert key value) =
        if predicate key value then Insert key value else Delete key
      filterOperation (Delete key) = Delete key
      filterOperation DeleteAll = DeleteAll

filter :: IsObservableMap k v a => (v -> Bool) -> a -> ObservableMap k v
filter predicate = filterWithKey (const predicate)

filterWithKey :: IsObservableMap k v a => (k -> v -> Bool) -> a -> ObservableMap k v
filterWithKey predicate upstream =
  toObservableMap (FilteredObservableMap predicate (toObservableMap upstream))


data ObservableMapValues v = forall k. Ord k => ObservableMapValues (ObservableMap k v)

instance ToObservable (Seq v) (ObservableMapValues v) where
  toObservable (ObservableMapValues x) = mapObservable (Seq.fromList . Map.elems) x

instance ToObservableList v (ObservableMapValues v)

instance IsObservableList v (ObservableMapValues v) where
  observeIsEmpty# (ObservableMapValues x) = observeIsEmpty# x

  observeLength# (ObservableMapValues x) = observeLength# x

  attachListDeltaObserver# (ObservableMapValues x) callback = do
    mfixExtra \initialFixed -> do
      var <- newTVar initialFixed
      (disposer, initial) <- attachMapDeltaObserver# x \(ObservableMapDelta mapOps) -> do
        listOperations <- forM mapOps \case
          Insert key value -> do
            (m, replaced) <- stateTVar var ((\(b, m) -> ((m, b), m)) . Map.insertCheckReplace key value)
            let index = Map.findIndex key m
            pure if replaced
              then Seq.fromList [ObservableList.Delete index, ObservableList.Insert index value]
              else Seq.singleton (ObservableList.Insert index value)
          Delete key -> do
            m <- readTVar var
            let i = Map.lookupIndex key m
            writeTVar var (Map.delete key m)
            pure case i of
              Nothing -> mempty
              Just i' -> Seq.singleton (ObservableList.Delete i')
          DeleteAll -> do
            writeTVar var mempty
            pure (Seq.singleton ObservableList.DeleteAll)
        callback (ObservableListDelta (fold listOperations))
      pure ((disposer, Seq.fromList (Map.elems initial)), initial)

values :: (Ord k, IsObservableMap k v a) => a -> ObservableList v
values x = toObservableList (ObservableMapValues (toObservableMap x))

items :: (Ord k, IsObservableMap k v a) => a -> ObservableList (k, v)
items x = values $ mapWithKey (,) x


data ObservableMapUnion k v = Ord k => ObservableMapUnion (k -> v -> v -> v) (ObservableMap k v) (ObservableMap k v)

instance ToObservable (Map k v) (ObservableMapUnion k v) where
  toObservable (ObservableMapUnion fn x y) =
    -- TODO use observableMapToObservable
    liftA2 (Map.unionWithKey fn) (toObservable x) (toObservable y)

instance ToObservableMap k v (ObservableMapUnion k v)

instance IsObservableMap k v (ObservableMapUnion k v) where
  observeIsEmpty# (ObservableMapUnion _fn x y) =
    deduplicateObservable (liftA2 (&&) (observeIsEmpty# x) (observeIsEmpty# y))

  observeLength# x =
    -- NOTE memory footprint could be improved by only tracking the keys (e.g. an (ObservableSet k))
    deduplicateObservable (Foldable.length <$> toObservable x)

  observeKey# key (ObservableMapUnion fn x y) =
    liftA2 (liftA2 (fn key)) (observeKey# key x) (observeKey# key y)

  attachMapDeltaObserver# (ObservableMapUnion fn ox oy) callback = do
    mfixExtra \initialFixed -> do
      var <- newTVar initialFixed
      (disposerX, initialX) <- attachMapDeltaObserver# ox \(ObservableMapDelta mapOps) -> do
        (x, y) <- readTVar var
        finalOps <- forM (toList mapOps) \case
          Insert key value -> do
            writeTVar var (Map.insert key value x, y)
            case Map.lookup key y of
              Nothing -> pure [Delete key]
              Just other -> pure [Insert key other]
          Delete key -> do
            writeTVar var (Map.delete key x, y)
            case Map.lookup key y of
              Nothing -> pure [Delete key]
              Just other -> pure [Insert key other]
          DeleteAll -> do
            writeTVar var (mempty, y)
            pure $ Map.keys x <&> \key ->
              case Map.lookup key y of
                Nothing -> Delete key
                Just other -> Insert key other
        callback (packDelta (join finalOps))
      (disposerY, initialY) <- attachMapDeltaObserver# oy \(ObservableMapDelta mapOps) -> do
        (x, y) <- readTVar var
        finalOps <- forM (toList mapOps) \case
          Insert key value -> do
            writeTVar var (x, Map.insert key value y)
            case Map.lookup key x of
              Nothing -> pure [Delete key]
              Just other -> pure [Insert key other]
          Delete key -> do
            writeTVar var (x, Map.delete key y)
            case Map.lookup key x of
              Nothing -> pure [Delete key]
              Just other -> pure [Insert key other]
          DeleteAll -> do
            writeTVar var (x, mempty)
            pure $ Map.keys y <&> \key ->
              case Map.lookup key x of
                Nothing -> Delete key
                Just other -> Insert key other
        callback (packDelta (join finalOps))

      let initial = Map.unionWithKey fn initialX initialY
      pure ((disposerX <> disposerY, initial), (initialX, initialY))

unionWithKey :: Ord k => (k -> v -> v -> v) -> ObservableMap k v -> ObservableMap k v -> ObservableMap k v
unionWithKey fn x y = ObservableMap (ObservableMapUnion fn x y)

unionWith :: Ord k => (v -> v -> v) -> ObservableMap k v -> ObservableMap k v -> ObservableMap k v
unionWith fn = unionWithKey \_ x y -> fn x y

union :: Ord k => ObservableMap k v -> ObservableMap k v -> ObservableMap k v
union = unionWithKey \_ x _ -> x

lookupMin :: ObservableMap k v -> Observable (Maybe (k, v))
lookupMin x = Map.lookupMin <$> toObservable x

lookupMax :: ObservableMap k v -> Observable (Maybe (k, v))
lookupMax x = Map.lookupMax <$> toObservable x
