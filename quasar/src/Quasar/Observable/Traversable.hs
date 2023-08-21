{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Quasar.Observable.Traversable (
  -- * Traversing deltas and selecting removed items
  TraversableObservableContainer(..),
  traverseChange,
  traverseChangeWithContext,
  observableChangeSelectRemoved,

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

instance TraversableObservableContainer c => TraversableObservableContainer (ObservableResult e c) where
  traverseDelta fn delta (Just x) = traverseDelta @c fn delta x
  traverseDelta _fn _delta Nothing = pure Nothing

  selectRemoved delta (ObservableResultOk x) = selectRemoved delta x
  selectRemoved _ (ObservableResultEx _ex) = []

observableChangeSelectRemoved :: TraversableObservableContainer c => ObservableChange l c v -> ObserverState l c a -> [a]
observableChangeSelectRemoved ObservableChangeLoadingClear state = foldr (:) [] state
observableChangeSelectRemoved ObservableChangeLoadingUnchanged _ = []
observableChangeSelectRemoved ObservableChangeLiveUnchanged _ = []
observableChangeSelectRemoved (ObservableChangeLiveUpdate (ObservableUpdateReplace _new)) state = foldr (:) [] state
observableChangeSelectRemoved (ObservableChangeLiveUpdate (ObservableUpdateDelta _delta)) ObserverStateLoadingCleared = []
observableChangeSelectRemoved (ObservableChangeLiveUpdate (ObservableUpdateDelta delta)) (ObserverStateLoadingCached state) = selectRemoved delta state
observableChangeSelectRemoved (ObservableChangeLiveUpdate (ObservableUpdateDelta delta)) (ObserverStateLive state) = selectRemoved delta state


traverseUpdate :: forall c v a m. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableUpdate c v -> Maybe (DeltaContext c) -> m (Maybe (ObservableUpdate c a))
traverseUpdate fn (ObservableUpdateReplace content) _context = do
  newContent <- traverse fn content
  pure (Just (ObservableUpdateReplace newContent))
traverseUpdate fn (ObservableUpdateDelta delta) (Just context) = do
  ObservableUpdateDelta <<$>> traverseDelta @c fn delta context
traverseUpdate _fn (ObservableUpdateDelta _delta) Nothing = pure Nothing

traverseChange :: forall canLoad c v a m b. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableChange canLoad c v -> ObserverState canLoad c b -> m (Maybe (ObservableChange canLoad c a))
traverseChange _fn ObservableChangeLoadingClear _state = pure (Just ObservableChangeLoadingClear)
traverseChange _fn ObservableChangeLoadingUnchanged _state = pure (Just ObservableChangeLoadingUnchanged)
traverseChange _fn ObservableChangeLiveUnchanged _state = pure (Just ObservableChangeLoadingUnchanged)
traverseChange fn (ObservableChangeLiveUpdate (ObservableUpdateReplace new)) ObserverStateLoadingCleared =
  Just . ObservableChangeLiveUpdate . ObservableUpdateReplace <$> traverse fn new
traverseChange fn (ObservableChangeLiveUpdate update) state = do
  traverseUpdate fn update (toInitialDeltaContext <$> state.maybe) <&> \case
    Nothing -> case state of
      -- An invalid delta still signals a change from "cached loading" to "live"
      ObserverStateLoadingCached _ -> Just ObservableChangeLiveUnchanged
      _ -> Nothing
    (Just traversedUpdate) -> Just (ObservableChangeLiveUpdate traversedUpdate)

traverseChangeWithContext :: forall canLoad c v a m b. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableChange canLoad c v -> ObserverContext canLoad c -> m (Maybe (ObservableChange canLoad c a))
traverseChangeWithContext _fn ObservableChangeLoadingClear _ctx = pure (Just ObservableChangeLoadingClear)
traverseChangeWithContext _fn ObservableChangeLoadingUnchanged _ctx = pure (Just ObservableChangeLoadingUnchanged)
traverseChangeWithContext _fn ObservableChangeLiveUnchanged _ctx = pure (Just ObservableChangeLoadingUnchanged)
traverseChangeWithContext fn (ObservableChangeLiveUpdate (ObservableUpdateReplace new)) ObserverContextLoadingCleared =
  Just . ObservableChangeLiveUpdate . ObservableUpdateReplace <$> traverse fn new
traverseChangeWithContext fn (ObservableChangeLiveUpdate update) ctx = do
  case ctx of
    ObserverContextLoadingCleared ->
      ObservableChangeLiveUpdate <<$>> traverseUpdate fn update Nothing
    ObserverContextLoadingCached dctx ->
      traverseUpdate fn update (Just dctx) <&> \case
        Just x -> Just (ObservableChangeLiveUpdate x)
        -- An invalid delta still signals a change from "cached loading" to "live"
        Nothing -> Just ObservableChangeLiveUnchanged
    ObserverContextLive dctx ->
      ObservableChangeLiveUpdate <<$>> traverseUpdate fn update (Just dctx)


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

      (fxDisposer, initial) <- attachObserver# fx \change -> do
        -- Var is only set to Nothing when the observer is destructed
        readTVar var >>= mapM_ \old -> do
          traverseChange fn change old >>= mapM_ \traversedChange -> do
            mapM_ disposeTSimpleDisposer (observableChangeSelectRemoved change old)
            let
              disposerChange = fst <$> traversedChange
              downstreamChange = snd <$> traversedChange
            mapM_ (writeTVar var . Just . snd) (applyObservableChange disposerChange old)
            callback downstreamChange

      bar <- traverse fn initial
      let iVar = createObserverState (fst <$> bar)
      let iState = snd <$> bar

      finalDisposer <- newUnmanagedTSimpleDisposer do
        mapM_ (mapM_ disposeTSimpleDisposer) =<< swapTVar var Nothing

      pure ((fxDisposer <> finalDisposer, iState), Just iVar)


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
