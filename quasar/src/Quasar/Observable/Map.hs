module Quasar.Observable.Map (
  union,
  unionWith,
  unionWithKey,
) where

import Control.Applicative
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Quasar.Observable.Core
import Quasar.Prelude


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
unionWithKey fn (DynObservable x) (DynObservable y) = DynObservable (ObservableMapUnionWith fn x y)
unionWithKey fn (ConstObservable x) (DynObservable y) = DynObservable (ObservableMapUnionWith fn x y)
unionWithKey fn (DynObservable x) (ConstObservable y) = DynObservable (ObservableMapUnionWith fn x y)
unionWithKey fn (ConstObservable x) (ConstObservable y) = ConstObservable (mergeObservableState (mergeObservableResult (Map.unionWithKey fn)) x y)

unionWith :: Ord k => (v -> v -> v) -> ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
unionWith fn = unionWithKey \_ x y -> fn x y

union :: Ord k => ObservableMap l e k v -> ObservableMap l e k v -> ObservableMap l e k v
-- TODO write union variant that only sends updates when needed (i.e. no update for a RHS change when the LHS has a value for that key)
union = unionWithKey \_ x _ -> x
