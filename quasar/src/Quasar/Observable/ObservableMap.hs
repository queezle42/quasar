module Quasar.Observable.ObservableMap (
  IsObservableMap(..),
  ObservableMap,

  ObservableMapVar,
  new,
  insert,
  delete,
  lookup,
) where

import Quasar.Observable
import Quasar.Observable.Internal.ObserverRegistry
import Quasar.Prelude
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map


class IsObservable (Map k v) a => IsObservableMap k v a where
  observeKey :: Ord k => k -> a -> Observable (Maybe v)
  observeKey key = observeKey key . toObservableMap

  toObservableMap :: a -> ObservableMap k v
  toObservableMap = ObservableMap

  {-# MINIMAL toObservableMap | observeKey #-}


data ObservableMap k v = forall a. IsObservableMap k v a => ObservableMap a

instance IsObservable (Map k v) (ObservableMap k v) where
  toObservable (ObservableMap x) = toObservable x

instance IsObservableMap k v (ObservableMap k v) where
  observeKey key (ObservableMap x) = observeKey key x
  toObservableMap = id

instance Functor (ObservableMap k) where
  fmap f x = toObservableMap (MappedObservableMap f x)


data MappedObservableMap k v = forall a. MappedObservableMap (a -> v) (ObservableMap k a)

instance IsObservable (Map k v) (MappedObservableMap k v) where
  toObservable (MappedObservableMap fn observable) = fn <<$>> toObservable observable

instance IsObservableMap k v (MappedObservableMap k v) where
  observeKey key (MappedObservableMap fn observable) = fn <<$>> observeKey key observable



data ObservableMapVar k v = ObservableMapVar {
  content :: ObservableVar (Map k v),
  keyObservers :: TVar (Map k (ObserverRegistry (Maybe v)))
}

instance IsObservable (Map k v) (ObservableMapVar k v) where
  toObservable ObservableMapVar{content} = toObservable content

instance IsObservableMap k v (ObservableMapVar k v) where
  observeKey key x = toObservable (ObservableMapVarKeyObservable key x)


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
  keyObservers <- newTVar Map.empty
  pure ObservableMapVar {content, keyObservers}

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
