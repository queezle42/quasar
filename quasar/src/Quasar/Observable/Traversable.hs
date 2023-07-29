{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Quasar.Observable.Traversable (
  -- * Traversing deltas and selecting removed items
  TraversableObservableContainer(..),
  traverseUpdate,

  -- * Traverse active observable items in STM
  observableTMapSTM,
  observableTAttachForEach,

  -- ** Support for `runForEach` and `mapSTM`
  TraversingObservable(..),
) where

import Control.Applicative hiding (empty)
import Control.Monad.Except
import Data.Functor.Identity (Identity(..))
import Quasar.Observable.Core
import Quasar.Prelude hiding (filter, lookup)
import Quasar.Resources.Disposer
import Quasar.Utils.Fix


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


-- * Traverse active observable items in STM

data TraversingObservable l e c v =
  forall va. TraversingObservable
    (va -> STMc NoRetry '[] (TSimpleDisposer, v))
    (ObservableT l e c va)

instance TraversableObservableContainer c => IsObservableCore l e c v (TraversingObservable l e c v) where
  readObservable# (TraversingObservable fn fx) = do
    x <- readObservable# fx
    mapped <- liftSTMc @NoRetry @'[] $ traverse fn x
    mapM_ (disposeTSimpleDisposer . fst) mapped
    pure (snd <$> mapped)

  attachObserver# (TraversingObservable fn fx) callback = do
    mfixTVar \var -> do

      (fxDisposer, initial) <- attachObserver# fx \case
        ObservableChangeLoadingClear -> do
          mapM_ (mapM_ disposeTSimpleDisposer) =<< swapTVar var Nothing
          callback ObservableChangeLoadingClear
        ObservableChangeLoadingUnchanged -> callback ObservableChangeLoadingUnchanged
        ObservableChangeLiveUnchanged -> callback ObservableChangeLiveUnchanged
        ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk new)) -> do
          mapM_ (mapM_ disposeTSimpleDisposer) =<< readTVar var
          result <- traverse fn new
          writeTVar var (Just (fst <$> result))
          callback (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk (snd <$> result))))
        ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx ex)) -> do
          mapM_ (mapM_ disposeTSimpleDisposer) =<< swapTVar var Nothing
          callback (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx ex)))
        ObservableChangeLiveUpdate (ObservableUpdateDelta delta) -> do
          readTVar var >>= \case
            -- Receiving a delta in a 'Cleared' or exception state is a no-op.
            Nothing -> pure ()
            Just disposers -> do
              mapM_ disposeTSimpleDisposer (selectRemoved delta disposers)
              traverseDelta @c fn delta (toInitialDeltaContext disposers) >>=
                mapM_ \traversedDelta -> do
                  mapM_ (writeTVar var . Just) (applyDelta (fst <$> traversedDelta) disposers)
                  callback (ObservableChangeLiveUpdate (ObservableUpdateDelta (snd <$> traversedDelta)))

      (initialState, initialVar) <- case initial of
        ObservableStateLoading -> pure (ObservableStateLoading, Nothing)
        ObservableStateLiveOk initial' -> do
          result <- traverse fn initial'
          pure (ObservableStateLiveOk (snd <$> result), Just (fst <$> result))
        ObservableStateLiveEx ex -> pure (ObservableStateLiveEx ex, Nothing)

      finalDisposer <- newUnmanagedTSimpleDisposer do
        mapM_ (mapM_ disposeTSimpleDisposer) =<< swapTVar var Nothing

      pure ((fxDisposer <> finalDisposer, initialState), initialVar)


observableTMapSTM ::
  (TraversableObservableContainer c, ContainerConstraint l e c v (TraversingObservable l e c v)) =>
  (va -> STMc NoRetry '[] (TSimpleDisposer, v)) ->
  ObservableT l e c va ->
  ObservableT l e c v
observableTMapSTM fn fx = ObservableT (TraversingObservable fn fx)

observableTAttachForEach ::
  forall l e c va.
  (TraversableObservableContainer c, ContainerConstraint l e c () (TraversingObservable l e c ())) =>
  (va -> STMc NoRetry '[] TSimpleDisposer) ->
  ObservableT l e c va ->
  STMc NoRetry '[] TSimpleDisposer
observableTAttachForEach fn fx = do
  (disposer, _) <- attachObserver# (observableTMapSTM ((,()) <<$>> fn) fx) \_ -> pure ()
  pure disposer
