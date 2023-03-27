module Quasar.Observable.ObservableMap (
  ToObservableMap(..),
  observeKey,
  attachDeltaObserver,
  IsObservableMap(..),
  ObservableMap,
  mapWithKey,
  values,
  items,

  ObservableMapDelta,
  ObservableMapOperation,

  ObservableMapVar,
  new,
  insert,
  delete,
  lookup,
  lookupDelete,

  filter,
  filterWithKey,
) where

import Data.Foldable (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Quasar.Observable
import Quasar.Observable.ObservableList (ObservableList, IsObservableList, ToObservableList(..))
import Quasar.Observable.ObservableList qualified as ObservableList
import Quasar.Prelude hiding (filter)
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix
import Quasar.Utils.Map qualified as Map


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
  attachDeltaObserver# :: a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Map k v)

observeKey :: (ToObservableMap k v a, Ord k) => k -> a -> Observable (Maybe v)
observeKey key x = observeKey# key (toObservableMap x)

attachDeltaObserver :: (ToObservableMap k v a, MonadSTMc NoRetry '[] m) => a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Map k v)
attachDeltaObserver x callback = liftSTMc $ attachDeltaObserver# (toObservableMap x) callback

data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance ToObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance ToObservableMap k v (ObservableMap k v) where
  toObservableMap = id

instance IsObservableMap k v (ObservableMap k v) where
  observeIsEmpty# (ObservableMap x) = observeIsEmpty# x
  observeLength# (ObservableMap x) = observeLength# x
  observeKey# key (ObservableMap x) = observeKey# key x
  attachDeltaObserver# (ObservableMap x) = attachDeltaObserver# x

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap (const f) x)


-- | A list of operations that is applied atomically to an `ObservableMap`.
type ObservableMapDelta k v = [ObservableMapOperation k v]

-- | A single operation that can be applied to an `ObservableMap`. Part of a
-- `ObservableMapDelta`.
--
-- Applying `Delete` to a non-existing key is a no-op.
data ObservableMapOperation k v = Insert k v | Delete k | DeleteAll

instance Functor (ObservableMapOperation k) where
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ DeleteAll = DeleteAll

data MappedObservableMap k v = forall a. MappedObservableMap (k -> a -> v) (ObservableMap k a)

instance ToObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = Map.mapWithKey fn <$> toObservable observable

instance ToObservableMap k v (MappedObservableMap k v)

instance IsObservableMap k v (MappedObservableMap k v) where
  observeIsEmpty# (MappedObservableMap _ observable) = observeIsEmpty# observable
  observeLength# (MappedObservableMap _ observable) = observeLength# observable
  observeKey# key (MappedObservableMap fn observable) = fn key <<$>> observeKey# key observable
  attachDeltaObserver# (MappedObservableMap fn observable) callback =
    Map.mapWithKey fn <<$>> attachDeltaObserver# observable \update -> callback (fmapDeltaWithKey fn <$> update)
    where
      fmapDeltaWithKey :: (k -> a -> b) -> ObservableMapOperation k a -> ObservableMapOperation k b
      fmapDeltaWithKey f (Insert k v) = Insert k (f k v)
      fmapDeltaWithKey _ (Delete k) = Delete k
      fmapDeltaWithKey _ DeleteAll = DeleteAll

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
  observeLength# x = deduplicateObservable (length <$> toObservable x)
  observeKey# key x = toObservable (ObservableMapVarKeyObservable key x)
  attachDeltaObserver# ObservableMapVar{content, deltaObservers} callback = do
    disposer <- registerCallback deltaObservers callback
    initial <- readTVar content
    pure (disposer, initial)


data ObservableMapVarKeyObservable k v = ObservableMapVarKeyObservable k (ObservableMapVar k v)

instance Ord k => ToObservable (Maybe v) (ObservableMapVarKeyObservable k v)

instance Ord k => IsObservable (Maybe v) (ObservableMapVarKeyObservable k v) where
  attachObserver# (ObservableMapVarKeyObservable key ObservableMapVar{content, keyObservers}) callback = do
    value <- Map.lookup key <$> readTVar content
    registry <- (Map.lookup key <$> readTVar keyObservers) >>= \case
      Just registry -> pure registry
      Nothing -> do
        registry <- newCallbackRegistryWithEmptyCallback (modifyTVar keyObservers (Map.delete key))
        modifyTVar keyObservers (Map.insert key registry)
        pure registry
    disposer <- registerCallback registry callback
    pure (disposer, value)

  readObservable# (ObservableMapVarKeyObservable key ObservableMapVar{content}) =
    Map.lookup key <$> readTVar content

new :: MonadSTMc NoRetry '[] m => m (ObservableMapVar k v)
new = liftSTMc @NoRetry @'[] do
  content <- newTVar Map.empty
  observers <- newCallbackRegistry
  deltaObservers <- newCallbackRegistry
  keyObservers <- newTVar Map.empty
  pure ObservableMapVar {content, observers, deltaObservers, keyObservers}

insert :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> v -> ObservableMapVar k v -> m ()
insert key value ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.insert key value)
  callCallbacks observers state
  callCallbacks deltaObservers [Insert key value]
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry (Just value)

delete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m ()
delete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.delete key)
  callCallbacks observers state
  callCallbacks deltaObservers [Delete key]
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry Nothing

lookupDelete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m (Maybe v)
lookupDelete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  (result, newMap) <- stateTVar content \orig ->
    let (result, newMap) = Map.lookupDelete key orig
    in ((result, newMap), newMap)
  callCallbacks observers newMap
  callCallbacks deltaObservers [Delete key]
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
    deduplicateObservable (length <$> toObservable x)

  observeKey# key (FilteredObservableMap predicate upstream) =
    find (predicate key) <$> observeKey# key upstream

  attachDeltaObserver# (FilteredObservableMap predicate upstream) callback =
    attachDeltaObserver# upstream \delta -> callback (filterDelta <$> delta)
    where
      filterDelta :: ObservableMapOperation k v -> ObservableMapOperation k v
      filterDelta (Insert key value) =
        if predicate key value then Insert key value else Delete key
      filterDelta (Delete key) = Delete key
      filterDelta DeleteAll = DeleteAll

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

  attachDeltaObserver# (ObservableMapValues x) callback = do
    mfixExtra \initialFixed -> do
      var <- newTVar initialFixed
      (disposer, initial) <- attachDeltaObserver# x \operations -> do
        listOperations <- forM operations \case
          Insert key value -> do
            m <- stateTVar var (dup . Map.insert key value)
            pure [ObservableList.Insert (Map.findIndex key m) value]
          Delete key -> do
            m <- readTVar var
            let i = Map.lookupIndex key m
            writeTVar var (Map.delete key m)
            pure (ObservableList.Delete <$> maybeToList i)
          DeleteAll -> do
            writeTVar var mempty
            pure [ObservableList.DeleteAll]
        callback (mconcat listOperations)
      pure ((disposer, Seq.fromList (Map.elems initial)), initial)

values :: (Ord k, IsObservableMap k v a) => a -> ObservableList v
values x = toObservableList (ObservableMapValues (toObservableMap x))

items :: (Ord k, IsObservableMap k v a) => a -> ObservableList (k, v)
items x = values $ mapWithKey (,) x
