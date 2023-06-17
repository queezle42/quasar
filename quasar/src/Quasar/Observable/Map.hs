{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Map (
  -- * ObservableMap
  ObservableMap,
  ToObservableMap,
  toObservableMap,

  -- ** Delta types
  ObservableMapDelta(..),
  ObservableMapOperation(..),

  -- ** Map functions
  union,
  unionWith,
  unionWithKey,
) where

import Control.Applicative
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Quasar.Observable.Core
import Quasar.Prelude


data MappedObservableMap canLoad k v = forall prev a. IsObservableCore canLoad (Map k) prev a => MappedObservableMap (k -> prev -> v) a

instance ObservableFunctor (Map k) => IsObservableCore canLoad (Map k) v (MappedObservableMap canLoad k v) where
  readObservable# (MappedObservableMap fn observable) =
    Map.mapWithKey fn <<$>> readObservable# observable

  attachObserver# (MappedObservableMap fn observable) callback =
    fmap2 (mapObservableState (Map.mapWithKey fn)) $ attachObserver# observable \final change ->
      callback final (mapObservableChangeDelta (mapDeltaWithKey fn) change)
    where
      mapDeltaWithKey :: (k -> prev -> v) -> ObservableMapDelta k prev -> ObservableMapDelta k v
      mapDeltaWithKey f (ObservableMapUpdate ops) = ObservableMapUpdate (Map.mapWithKey (mapOperationWithKey f) ops)
      mapDeltaWithKey f (ObservableMapReplace new) = ObservableMapReplace (Map.mapWithKey f new)
      mapOperationWithKey :: (k -> prev -> v) -> k -> ObservableMapOperation prev -> ObservableMapOperation v
      mapOperationWithKey f key (ObservableMapInsert x) = ObservableMapInsert (f key x)
      mapOperationWithKey _f _key ObservableMapDelete = ObservableMapDelete

  count# (MappedObservableMap _ upstream) = count# upstream
  isEmpty# (MappedObservableMap _ upstream) = isEmpty# upstream
  -- TODO lookup functions

  --mapObservable# f1 (MappedObservableMap f2 upstream) =
  --  DynObservableCore $ MappedObservableMap (f1 . f2) upstream


data ObservableMapUnionWith l e k v = forall a b. (IsObservableCore l (ObservableResult e (Map k)) v a, IsObservableCore l (ObservableResult e (Map k)) v b) => ObservableMapUnionWith (k -> v -> v -> v) a b

instance Ord k => IsObservableCore canLoad (ObservableResult exceptions (Map k)) v (ObservableMapUnionWith canLoad exceptions k v) where
  readObservable# (ObservableMapUnionWith fn fx fy) = do
    (finalX, x) <- readObservable# fx
    (finalY, y) <- readObservable# fy
    pure (finalX && finalY, mergeObservableResult (Map.unionWithKey fn) x y)

  attachObserver# (ObservableMapUnionWith fn fx fy) =
    attachMonoidMergeObserver fullMergeFn (deltaFn fn) (deltaFn (flip <$> fn)) fx fy
    where
      fullMergeFn :: Map k v -> Map k v -> Map k v
      fullMergeFn = Map.unionWithKey fn
      deltaFn :: (k -> v -> v -> v) -> ObservableMapDelta k v -> Map k v -> Map k v -> Maybe (ObservableMapDelta k v)
      deltaFn f (ObservableMapUpdate ops) _prev other =
        Just (ObservableMapUpdate (Map.fromList ((\(k, v) -> (k, helper k v)) <$> Map.toList ops)))
        where
          helper :: k -> ObservableMapOperation v -> ObservableMapOperation v
          helper key (ObservableMapInsert x) = ObservableMapInsert do
            maybe x (f key x) (Map.lookup key other)
          helper key ObservableMapDelete =
            maybe ObservableMapDelete ObservableMapInsert (Map.lookup key other)
      deltaFn f (ObservableMapReplace new) prev other =
        deltaFn f (ObservableMapUpdate (Map.union (ObservableMapInsert <$> new) (ObservableMapDelete <$ prev))) prev other


unionWithKey :: Ord k => (k -> v -> v -> v) -> ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
unionWithKey fn (Observable x) (Observable y) = Observable (ObservableCore (ObservableMapUnionWith fn x y))

unionWith :: Ord k => (v -> v -> v) -> ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
unionWith fn = unionWithKey \_ x y -> fn x y

union :: Ord k => ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
-- TODO write union variant that only sends updates when needed (i.e. no update for a RHS change when the LHS has a value for that key)
union = unionWithKey \_ x _ -> x
