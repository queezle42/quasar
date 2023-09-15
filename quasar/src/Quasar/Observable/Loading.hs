module Quasar.Observable.Loading (
  loadingToMaybe,
  loadingOrElse,
  stripLoading,
  isLoading,

  -- ** ObservableT
  observableTStripLoading,
  observableTIsLoading,

  -- * Implementation types
  StripLoading(..),
) where

import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Prelude
import Quasar.Utils.Fix (mfixTVar)


newtype LoadingToMaybe canLoad exceptions v = LoadingToMaybe (Observable canLoad exceptions v)

instance IsObservableCore NoLoad exceptions Identity (Maybe v) (LoadingToMaybe canLoad exceptions v) where
  readObservable# (LoadingToMaybe f) = do
    readObservable# f <&> \case
      ObservableStateLoading -> ObservableStateLive (ObservableResultOk (Identity Nothing))
      ObservableStateLive x -> ObservableStateLive (Just <$> x)

  attachObserver# (LoadingToMaybe f) callback = do
    mfixTVar \var -> do
      (disposer, initial) <- attachObserver# f \change -> do
        oldState <- readTVar var
        forM_ (applyObservableChange change oldState) \(_evaluatedChange, newState) -> do
          writeTVar var newState
          case (oldState.loading, newState.loading) of
            (Loading, Loading) -> pure () -- unchanged Loading (i.e. from LoadingCached to LoadingCleared)
            _ -> do
              callback $ ObservableChangeLiveReplace case newState of
                ObserverStateLoadingCleared -> ObservableResultOk (Identity Nothing)
                ObserverStateLoadingCached _ -> ObservableResultOk (Identity Nothing)
                ObserverStateLive x -> Just <$> x

      let initialResult = case initial of
            ObservableStateLoading -> ObservableStateLive (ObservableResultOk (Identity Nothing))
            ObservableStateLive x -> ObservableStateLive (Just <$> x)

      pure ((disposer, initialResult), createObserverState initial)


-- | Replace any `Loading` state with `Nothing`.
loadingToMaybe ::
  Observable canLoad exceptions v ->
  Observable NoLoad exceptions (Maybe v)
loadingToMaybe f = Observable (ObservableT (LoadingToMaybe f))

-- | Replace any `Loading` state with another observable.
loadingOrElse ::
  Observable Load exceptions v ->
  Observable canLoad exceptions v ->
  Observable canLoad exceptions v
loadingOrElse fx fy = liftObservable (loadingToMaybe fx) >>= maybe fy pure



data StripLoading exceptions c v = StripLoading (c v) (ObservableT Load exceptions c v)

instance IsObservableCore NoLoad exceptions c v (StripLoading exceptions c v) where
  readObservable# (StripLoading initial fx) = do
    readObservable# fx >>= \case
      ObservableStateLoading -> pure (ObservableStateLive (ObservableResultOk initial))
      (ObservableStateLive x) -> pure (ObservableStateLive x)

  attachObserver# (StripLoading initialFallback fx) callback = do
    mfixTVar \var -> do
      (disposer, initial) <- attachObserver# fx \case
        ObservableChangeLoadingClear ->
          writeTVar var False
        ObservableChangeLoadingUnchanged -> pure ()
        ObservableChangeLiveUnchanged -> pure ()
        (ObservableChangeLiveReplace new) -> do
          writeTVar var True
          callback (ObservableChangeLiveReplace new)
        (ObservableChangeLiveDelta delta) -> do
          whenM (readTVar var) do
            callback (ObservableChangeLiveDelta delta)

      let (initialResult, initialVar) = case initial of
            ObservableStateLoading -> (ObservableStateLive (ObservableResultOk initialFallback), False)
            (ObservableStateLive x) -> (ObservableStateLive x, True)

      pure ((disposer, initialResult), initialVar)

-- | Strip any loading events. The resulting observable retains the last live
-- value until the input observable changes again.
--
-- If the initial state is Loading, the fallback state will be used instead.
observableTStripLoading ::
  ContainerConstraint NoLoad exceptions c v (StripLoading exceptions c v) =>
  c v ->
  ObservableT Load exceptions c v ->
  ObservableT NoLoad exceptions c v
observableTStripLoading initialFallback f = ObservableT (StripLoading initialFallback f)

stripLoading ::
  v ->
  Observable Load exceptions v ->
  Observable NoLoad exceptions v
stripLoading initialFallback (Observable f) =
  Observable (observableTStripLoading (Identity initialFallback) f)



newtype IsLoading canLoad exceptions c v = IsLoading (ObservableT canLoad exceptions c v)

instance ObservableContainer c v => IsObservableCore NoLoad '[] Identity (Loading canLoad) (IsLoading canLoad exceptions c v) where
  readObservable# (IsLoading fx) = do
    readObservable# fx <&> \case
      ObservableStateLoading -> ObservableStateLive (ObservableResultOk (Identity Loading))
      (ObservableStateLive _) -> ObservableStateLive (ObservableResultOk (Identity Live))

  attachObserver# (IsLoading fx) callback = do
    -- Var stores a bool that represents "cached or live" (i.e. not cleared)
    mfixTVar \isValidVar -> do
      mfixTVar \lastLoadingVar -> do
        (disposer, initial) <- attachObserver# fx \case
          ObservableChangeLoadingClear -> do
            writeTVar isValidVar False
            send lastLoadingVar Loading
          ObservableChangeLoadingUnchanged ->
            send lastLoadingVar Loading
          ObservableChangeLiveUnchanged ->
            whenM (readTVar isValidVar) do
              send lastLoadingVar Loading
          (ObservableChangeLiveReplace _new) -> do
            writeTVar isValidVar True
            send lastLoadingVar Live
          (ObservableChangeLiveDelta delta) ->
            whenM (readTVar isValidVar) do
              send lastLoadingVar Live

        let (initialIsLoading, initialIsValid) = case initial of
              ObservableStateLoading -> (Loading, False)
              (ObservableStateLive _) -> (Live, True)

        pure (((disposer, ObservableStateLive (ObservableResultOk (Identity initialIsLoading))), initialIsValid), initialIsLoading)
    where
      send :: TVar (Loading canLoad) -> Loading canLoad -> STMc NoRetry '[] ()
      send lastVar loading = do
        last <- readTVar lastVar
        when (last /= loading) do
          writeTVar lastVar loading
          callback (ObservableChangeLiveReplace (ObservableResultOk (Identity loading)))

observableTIsLoading :: ObservableContainer c v => ObservableT canLoad exceptions c v -> Observable NoLoad '[] (Loading canLoad)
observableTIsLoading f = Observable (ObservableT (IsLoading f))

isLoading :: Observable canLoad exceptions v -> Observable NoLoad '[] (Loading canLoad)
isLoading (Observable f) = observableTIsLoading f
