{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ImpredicativeTypes #-}

module Quasar.Observable.Traversable (
  -- * Traversing deltas and selecting removed items
  TraversableObservableContainer(..),
  traverseChange,
  traverseChangeWithContext,
  selectRemovedByChange,

  -- * Traverse active observable items in STM
  traverseObservableT,
  attachForEachObservableT,

  -- ** Support for `runForEach` and `mapSTM`
  TraversingObservable(..),
) where

import Control.Applicative hiding (empty)
import Data.Traversable (for)
import Quasar.Disposer
import Quasar.Observable.Core
import Quasar.Prelude hiding (filter, lookup)
import Quasar.Utils.Fix


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
    (va -> STMc NoRetry '[] v)
    (v -> STMc NoRetry '[] ())
    (ObservableT l e c va)

instance TraversableObservableContainer c => IsObservableCore l e c v (TraversingObservable l e c v) where
  readObservable# (TraversingObservable addFn removeFn fx) = do
    x <- readObservable# fx
    items <- liftSTMc @NoRetry @'[] $ traverse addFn x
    mapM_ removeFn items
    pure items

  attachObserver# (TraversingObservable addFn removeFn fx) callback = do
    mfixTVar \var -> do

      (fxDisposer, initial) <- attachObserver# fx \change -> do
        -- Var is only set to Nothing when the observer is destructed
        readTVar var >>= mapM_ \old -> do
          traverseChange addFn change old >>= mapM_ \traversedChange -> do
            mapM_ removeFn (selectRemovedByChange change old)
            mapM_ (writeTVar var . Just . snd) (applyObservableChange traversedChange old)
            callback traversedChange

      bar <- traverse addFn initial
      let iVar = createObserverState bar
      let iState = bar

      finalDisposer <- newTDisposer do
        mapM_ (mapM_ removeFn) =<< swapTVar var Nothing

      pure ((fxDisposer <> finalDisposer, iState), Just iVar)


traverseObservableT ::
  forall c l e va v.
  (TraversableObservableContainer c, ContainerConstraint l e c v (TraversingObservable l e c v)) =>
  (va -> STMc NoRetry '[] v) ->
  (v -> STMc NoRetry '[] ()) ->
  ObservableT l e c va ->
  ObservableT l e c v
traverseObservableT addFn removeFn fx = ObservableT (TraversingObservable addFn removeFn fx)

attachForEachObservableT ::
  forall c l e va v.
  (TraversableObservableContainer c, ContainerConstraint l e c v (TraversingObservable l e c v)) =>
  (va -> STMc NoRetry '[] v) ->
  (v -> STMc NoRetry '[] ()) ->
  ObservableT l e c va ->
  STMc NoRetry '[] TDisposer
attachForEachObservableT addFn removeFn fx = do
  (disposer, _) <- attachObserver# (traverseObservableT addFn removeFn fx) \_ -> pure ()
  pure disposer
