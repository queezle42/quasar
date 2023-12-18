{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ImpredicativeTypes #-}

module Quasar.Observable.Traversable (
  -- * Traversing deltas and selecting removed items
  TraversableObservableContainer(..),
  traverseChange,
  traverseChangeWithContext,
  selectRemovedByChange,

  -- * Traverse active observable items in STM
  observableTMapSTM,
  observableTAttachForEach,

  -- ** Support for `runForEach` and `mapSTM`
  TraversingObservable(..),
) where

import Control.Applicative hiding (empty)
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Prelude hiding (filter, lookup)
import Quasar.Resources.Disposer
import Quasar.Utils.Fix
import Data.Traversable (for)


-- * Selecting removals from a delta

class (ObservableFunctor c, Traversable c, Traversable (ValidatedDelta c)) => TraversableObservableContainer c where
  selectRemoved :: Delta c v -> c a -> [a]

instance TraversableObservableContainer Identity where
  selectRemoved _update (Identity old) = [old]

instance TraversableObservableContainer c => TraversableObservableContainer (ObservableResult e c) where
  selectRemoved delta (ObservableResultOk x) = selectRemoved delta x
  selectRemoved _ (ObservableResultEx _ex) = []

selectRemovedByChange :: TraversableObservableContainer c => ObservableChange l c v -> ObserverState l c a -> [a]
selectRemovedByChange ObservableChangeLoadingClear state = foldr (:) [] state
selectRemovedByChange ObservableChangeLoadingUnchanged _ = []
selectRemovedByChange ObservableChangeLiveUnchanged _ = []
selectRemovedByChange (ObservableChangeLiveReplace _new) state = foldr (:) [] state
selectRemovedByChange (ObservableChangeLiveDelta _delta) ObserverStateLoadingCleared = []
selectRemovedByChange (ObservableChangeLiveDelta delta) (ObserverStateLoadingCached state) = selectRemoved delta state
selectRemovedByChange (ObservableChangeLiveDelta delta) (ObserverStateLive state) = selectRemoved delta state


traverseChange :: forall canLoad c v a m b. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableChange canLoad c v -> ObserverState canLoad c b -> m (Maybe (ObservableChange canLoad c a))
traverseChange fn change state = traverseChangeWithContext fn change state.context

traverseChangeWithContext :: forall canLoad c v a m b. (Applicative m, TraversableObservableContainer c) => (v -> m a) -> ObservableChange canLoad c v -> ObserverContext canLoad c -> m (Maybe (ObservableChange canLoad c a))
traverseChangeWithContext fn change ctx = do
  for (validateChange ctx change) \valid ->
    (.unvalidated) <$> traverse fn valid


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
            mapM_ disposeTSimpleDisposer (selectRemovedByChange change old)
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
