module Quasar.Observable.ObservableMap (
  IsObservableMap(..),
  ObservableMap,

  ObservableMapVar,
  new,
  insert,
  delete,
  lookup,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Quasar.Observable
import Quasar.Observable.Internal.ObserverRegistry
import Quasar.Prelude
import Quasar.Resources.Disposer


class IsObservable (Map k v) a => IsObservableMap k v a where
  observeKey :: Ord k => k -> a -> Observable (Maybe v)
  observeKey key = observeKey key . toObservableMap

  attachUpdateListener :: a -> (ObservableMapUpdate k v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] TSimpleDisposer
  attachUpdateListener x = attachUpdateListener (toObservableMap x)

  toObservableMap :: a -> ObservableMap k v
  toObservableMap = ObservableMap

  {-# MINIMAL toObservableMap | observeKey, attachUpdateListener #-}


data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance IsObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance IsObservableMap k v (ObservableMap k v) where
  observeKey key (ObservableMap x) = observeKey key x
  toObservableMap = id

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap f x)


type ObservableMapUpdate k v = [ObservableMapDelta k v]

data ObservableMapDelta k v = Reset | Insert k v | Delete k | Rename k k

instance Functor (ObservableMapDelta k) where
  fmap _ Reset = Reset
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ (Rename k0 k1) = Rename k0 k1

initialObservableMapDelta :: Map k v -> [ObservableMapDelta k v]
initialObservableMapDelta = fmap (\(k, v) -> Insert k v) . Map.toList


data MappedObservableMap k v = forall a. MappedObservableMap (a -> v) (ObservableMap k a)

instance IsObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = fn <<$>> toObservable observable

instance IsObservableMap k v (MappedObservableMap k v) where
  observeKey key (MappedObservableMap fn observable) = fn <<$>> observeKey key observable
  attachUpdateListener (MappedObservableMap fn observable) callback =
    attachUpdateListener observable (\update -> callback (fn <<$>> update))


data ObservableMapVar k v = ObservableMapVar {
  content :: ObservableVar (Map k v),
  deltaListeners :: ObserverRegistry [ObservableMapDelta k v],
  keyObservers :: TVar (Map k (ObserverRegistry (Maybe v)))
}

instance IsObservable (Map k v) (ObservableMapVar k v) where
  toObservable ObservableMapVar{content} = toObservable content

instance IsObservableMap k v (ObservableMapVar k v) where
  observeKey key x = toObservable (ObservableMapVarKeyObservable key x)
  attachUpdateListener ObservableMapVar{content, deltaListeners} callback = do
    initial <- initialObservableMapDelta <$> readObservable content
    registerObserver deltaListeners callback initial


data ObservableMapVarKeyObservable k v = ObservableMapVarKeyObservable k (ObservableMapVar k v)

instance Ord k => IsObservable (Maybe (v)) (ObservableMapVarKeyObservable k v) where
  attachObserver (ObservableMapVarKeyObservable key ObservableMapVar{content, keyObservers}) callback = do
    value <- Map.lookup key <$> readObservable content
    registry <- (Map.lookup key <$> readTVar keyObservers) >>= \case
      Just registry -> pure registry
      Nothing -> do
        registry <- newObserverRegistryWithEmptyCallback (modifyTVar keyObservers (Map.delete key))
        modifyTVar keyObservers (Map.insert key registry)
        pure registry
    registerObserver registry callback value

  readObservable (ObservableMapVarKeyObservable key ObservableMapVar{content}) =
    Map.lookup key <$> readObservable content

new :: MonadSTMc NoRetry '[] m => m (ObservableMapVar k v)
new = liftSTMc @NoRetry @'[] do
  content <- newObservableVar Map.empty
  deltaListeners <- newObserverRegistry
  keyObservers <- newTVar Map.empty
  pure ObservableMapVar {content, deltaListeners, keyObservers}

insert :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> v -> ObservableMapVar k v -> m ()
insert key value ObservableMapVar{content, keyObservers} = liftSTMc @NoRetry @'[] do
  modifyObservableVar content (Map.insert key value)
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> updateObservers keyRegistry (Just value)

delete :: forall k v m. (Ord k, MonadSTMc NoRetry '[] m) => k -> ObservableMapVar k v -> m ()
delete key ObservableMapVar{content, keyObservers} = liftSTMc @NoRetry @'[] do
  modifyObservableVar content (Map.delete key)
  mkr <- Map.lookup key <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> updateObservers keyRegistry Nothing
