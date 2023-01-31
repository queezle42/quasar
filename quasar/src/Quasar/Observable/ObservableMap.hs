module Quasar.Observable.ObservableMap (
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
) where

import Control.Monad.State.Lazy qualified as State
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Tuple (swap)
import Quasar.Observable
import Quasar.Observable.Internal.ObserverRegistry
import Quasar.Prelude hiding (lookupDelete)
import Quasar.Resources.Disposer


class IsObservable (Map k v) a => IsObservableMap k v a where
  observeKey :: Ord k => k -> a -> Observable (Maybe v)
  observeKey key = observeKey key . toObservableMap

  -- | Register a listener to observe changes to the whole map. The callback
  -- will be invoked with the current state of the map immediately after
  -- registering and after that will be invoked for every change to the map.
  attachDeltaObserver :: a -> (ObservableMapDelta k v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] TSimpleDisposer
  attachDeltaObserver x = attachDeltaObserver (toObservableMap x)

  toObservableMap :: a -> ObservableMap k v
  toObservableMap = ObservableMap

  {-# MINIMAL toObservableMap | observeKey, attachDeltaObserver #-}


data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance IsObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance IsObservableMap k v (ObservableMap k v) where
  observeKey key (ObservableMap x) = observeKey key x
  toObservableMap = id

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap f x)


-- | A list of operations that is applied atomically to an `ObservableMap`.
type ObservableMapDelta k v = [ObservableMapOperation k v]

-- | A single operation that can be applied to an `ObservableMap`. Part of a
-- `ObservableMapDelta`.
data ObservableMapOperation k v = Insert k v | Delete k | Move k k | DeleteAll

instance Functor (ObservableMapOperation k) where
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ (Move k0 k1) = Move k0 k1
  fmap _ DeleteAll = DeleteAll

initialObservableMapDelta :: Map k v -> ObservableMapDelta k v
initialObservableMapDelta = fmap (\(k, v) -> Insert k v) . Map.toList


data MappedObservableMap k v = forall a. MappedObservableMap (a -> v) (ObservableMap k a)

instance IsObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = fn <<$>> toObservable observable

instance IsObservableMap k v (MappedObservableMap k v) where
  observeKey key (MappedObservableMap fn observable) = fn <<$>> observeKey key observable
  attachDeltaObserver (MappedObservableMap fn observable) callback =
    attachDeltaObserver observable (\update -> callback (fn <<$>> update))


data ObservableMapVar k v = ObservableMapVar {
  content :: TVar (Map k v),
  observers :: ObserverRegistry (Map k v),
  deltaObservers :: ObserverRegistry (ObservableMapDelta k v),
  keyObservers :: TVar (Map k (ObserverRegistry (Maybe v)))
}

instance IsObservable (Map k v) (ObservableMapVar k v) where
  readObservable ObservableMapVar{content} = readTVar content
  attachObserver ObservableMapVar{content, observers} callback =
    registerObserver observers callback =<< readTVar content

instance IsObservableMap k v (ObservableMapVar k v) where
  observeKey key x = toObservable (ObservableMapVarKeyObservable key x)
  attachDeltaObserver ObservableMapVar{content, deltaObservers} callback = do
    initial <- initialObservableMapDelta <$> readTVar content
    registerObserver deltaObservers callback initial


data ObservableMapVarKeyObservable k v = ObservableMapVarKeyObservable k (ObservableMapVar k v)

instance Ord k => IsObservable (Maybe (v)) (ObservableMapVarKeyObservable k v) where
  attachObserver (ObservableMapVarKeyObservable key ObservableMapVar{content, keyObservers}) callback = do
    value <- Map.lookup key <$> readTVar content
    registry <- (Map.lookup key <$> readTVar keyObservers) >>= \case
      Just registry -> pure registry
      Nothing -> do
        registry <- newObserverRegistryWithEmptyCallback (modifyTVar keyObservers (Map.delete key))
        modifyTVar keyObservers (Map.insert key registry)
        pure registry
    registerObserver registry callback value

  readObservable (ObservableMapVarKeyObservable key ObservableMapVar{content}) =
    Map.lookup key <$> readTVar content

new :: MonadSTMc NoRetry '[] m => m (ObservableMapVar k v)
new = liftSTMc @NoRetry @'[] do
  content <- newTVar Map.empty
  observers <- newObserverRegistry
  deltaObservers <- newObserverRegistry
  keyObservers <- newTVar Map.empty
  pure ObservableMapVar {content, observers, deltaObservers, keyObservers}

insert :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> v -> ObservableMapVar k v -> m ()
insert key value ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.insert key value)
  updateObservers observers state
  updateObservers deltaObservers [Insert key value]
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> updateObservers keyRegistry (Just value)

delete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m ()
delete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  state <- stateTVar content (dup . Map.delete key)
  updateObservers observers state
  updateObservers deltaObservers [Delete key]
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> updateObservers keyRegistry Nothing

lookupDelete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m (Maybe v)
lookupDelete key ObservableMapVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  (result, newMap) <- stateTVar content \orig ->
    let (result, newMap) = mapLookupDelete key orig
    in ((result, newMap), newMap)
  updateObservers observers newMap
  updateObservers deltaObservers [Delete key]
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> updateObservers keyRegistry Nothing
  pure result
  where
    -- | Lookup and delete a value from a Map in one operation
    mapLookupDelete :: forall k v. Ord k => k -> Map k v -> (Maybe v, Map k v)
    mapLookupDelete key m = swap $ State.runState fn Nothing
      where
        fn :: State.State (Maybe v) (Map k v)
        fn = Map.alterF (\c -> State.put c >> pure Nothing) key m
