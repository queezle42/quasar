{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Quasar.Observable.Traversable (
  -- * Traversing deltas and selecting removed items
  TraversableObservableContainer(..),
  traverseUpdate,
) where

import Control.Applicative hiding (empty)
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Quasar.Observable.Core
import Quasar.Prelude hiding (filter, lookup)


-- * Selecting removals from a delta

class (Traversable c, Functor (Delta c), forall a. ObservableContainer c a) => TraversableObservableContainer c where
  traverseDelta :: Applicative m => (v -> m a) -> Delta c v -> DeltaContext c -> m (Maybe (Delta c a))
  default traverseDelta :: (Traversable (Delta c), Applicative m) => (v -> m a) -> Delta c v -> DeltaContext c -> m (Maybe (Delta c a))
  traverseDelta fn delta _ = Just <$> traverse fn delta

  selectRemoved :: Delta c v -> c a -> [a]

instance TraversableObservableContainer Identity where
  selectRemoved _update (Identity old) = [old]

instance TraversableObservableContainer c => TraversableObservableContainer (ObservableResult '[SomeException] c) where
  traverseDelta fn delta (Just x) = traverseDelta @c fn delta x
  traverseDelta _fn _delta Nothing = pure Nothing

  selectRemoved delta (ObservableResultOk x) = selectRemoved delta x
  selectRemoved _ (ObservableResultEx _ex) = []


traverseUpdate :: forall c v a m. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableUpdate c v -> Maybe (DeltaContext c) -> m (Maybe (ObservableUpdate c a, DeltaContext c))
traverseUpdate fn (ObservableUpdateReplace content) _context = do
  newContent <- traverse fn content
  pure (Just (ObservableUpdateReplace newContent, toInitialDeltaContext @c newContent))
traverseUpdate fn (ObservableUpdateDelta delta) (Just context) = do
  traverseDelta @c fn delta context <<&>> \newDelta ->
    (ObservableUpdateDelta newDelta, updateDeltaContext @c context delta)
traverseUpdate _fn (ObservableUpdateDelta _delta) Nothing = pure Nothing
