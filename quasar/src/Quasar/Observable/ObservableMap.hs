module Quasar.Observable.ObservableMap (
  ToObservableMap(..),
  observeKey,
  attachDeltaObserver,
  IsObservableMap(..),
  ObservableMap,

  ObservableMapDelta,
  ObservableMapOperation,

  ObservableMapVar,
  new,
  insert,
  delete,
  lookup,
  lookupDelete,

  filter,
) where

import Data.Foldable (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Quasar.Observable
import Quasar.Prelude hiding (filter)
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Map qualified as Map


class ToObservable (Map k v) a => ToObservableMap k v a where
  toObservableMap :: a -> ObservableMap k v
  default toObservableMap :: IsObservableMap k v a => a -> ObservableMap k v
  toObservableMap = ObservableMap

class ToObservableMap k v a => IsObservableMap k v a where
  {-# MINIMAL observeKey#, attachDeltaObserver# #-}

  observeKey# :: Ord k => k -> a -> Observable (Maybe v)
  observeKey# key = observeKey# key . toObservableMap

  -- | Register a listener to observe changes to the whole map. The callback
  -- will be invoked with the current state of the map immediately after
  -- registering and after that will be invoked for every change to the map.
  attachDeltaObserver# :: a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] TSimpleDisposer
  attachDeltaObserver# x = attachDeltaObserver# (toObservableMap x)

observeKey :: (ToObservableMap k v a, Ord k) => k -> a -> Observable (Maybe v)
observeKey key x = observeKey# key (toObservableMap x)

attachDeltaObserver :: (ToObservableMap k v a, MonadSTMc NoRetry '[] m) => a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> m TSimpleDisposer
attachDeltaObserver x callback = liftSTMc $ attachDeltaObserver# (toObservableMap x) callback

data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance ToObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance ToObservableMap k v (ObservableMap k v) where
  toObservableMap = id

instance IsObservableMap k v (ObservableMap k v) where
  observeKey# key (ObservableMap x) = observeKey# key x
  attachDeltaObserver# (ObservableMap x) = attachDeltaObserver# x

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap f x)


-- | A list of operations that is applied atomically to an `ObservableMap`.
type ObservableMapDelta k v = [ObservableMapOperation k v]

-- | A single operation that can be applied to an `ObservableMap`. Part of a
-- `ObservableMapDelta`.
--
-- Applying `Delete` to a non-existing key is a no-op.
--
-- Applying `Move` with a non-existent source key behaves like a `Delete` on the
-- target key.
data ObservableMapOperation k v = Insert k v | Delete k | Move k k | DeleteAll

instance Functor (ObservableMapOperation k) where
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ (Move k0 k1) = Move k0 k1
  fmap _ DeleteAll = DeleteAll

initialObservableMapDelta :: Map k v -> ObservableMapDelta k v
initialObservableMapDelta = fmap (\(k, v) -> Insert k v) . Map.toList


data MappedObservableMap k v = forall a. MappedObservableMap (a -> v) (ObservableMap k a)

instance ToObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = fn <<$>> toObservable observable

instance ToObservableMap k v (MappedObservableMap k v)

instance IsObservableMap k v (MappedObservableMap k v) where
  observeKey# key (MappedObservableMap fn observable) = fn <<$>> observeKey# key observable
  attachDeltaObserver# (MappedObservableMap fn observable) callback =
    attachDeltaObserver# observable (\update -> callback (fn <<$>> update))


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
  observeKey# key x = toObservable (ObservableMapVarKeyObservable key x)
  attachDeltaObserver# ObservableMapVar{content, deltaObservers} callback = do
    disposer <- registerCallback deltaObservers callback
    callback =<< initialObservableMapDelta <$> readTVar content
    pure disposer


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

data FilteredObservableMap k v = FilteredObservableMap (v -> Bool) (ObservableMap k v)

instance ToObservable (Map k v) (FilteredObservableMap k v) where
  toObservable (FilteredObservableMap predicate upstream) =
    mapObservable (Map.filter predicate) upstream

instance ToObservableMap k v (FilteredObservableMap k v)

instance IsObservableMap k v (FilteredObservableMap k v) where
  observeKey# key (FilteredObservableMap predicate upstream) =
    find predicate <$> observeKey# key upstream

  attachDeltaObserver# (FilteredObservableMap predicate upstream) callback =
    attachDeltaObserver# upstream \delta -> callback (filterDelta <$> delta)
    where
      filterDelta :: ObservableMapOperation k v -> ObservableMapOperation k v
      filterDelta (Insert key value) =
        if predicate value then Insert key value else Delete key
      filterDelta (Delete key) = Delete key
      filterDelta (Move k0 k1) = Move k0 k1
      filterDelta DeleteAll = DeleteAll

filter :: IsObservableMap k v a => (v -> Bool) -> a -> ObservableMap k v
filter predicate upstream =
  toObservableMap (FilteredObservableMap predicate (toObservableMap upstream))
