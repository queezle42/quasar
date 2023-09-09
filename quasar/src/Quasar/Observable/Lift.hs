{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Lift (
  liftObservableT,
  liftObservable,

  -- ** Constraints
  RelaxLoad(..),

  -- *** Reexports
  (:<<),
  (:<),

  -- ** Observable operation type
  LiftedObservable(..),
) where

import Quasar.Observable.Core
import Quasar.Prelude


liftObservableT ::
  forall la ea l e c v m.
  (ea :<< e, RelaxLoad la l, ObservableContainer c v, ContainerConstraint l e c v (LiftedObservable l e la ea c v)) =>
  ObservableT la ea c v -> ObservableT l e c v
liftObservableT fx = ObservableT (LiftedObservable @l @e fx)

liftObservable ::
  forall la ea l e v.
  (ea :<< e, RelaxLoad la l) =>
  Observable la ea v -> Observable l e v
liftObservable (Observable fx) = Observable (liftObservableT fx)


newtype LiftedObservable l e la ea c v = LiftedObservable (ObservableT la ea c v)

instance (ea :<< e, RelaxLoad la l, ObservableContainer c v) => IsObservableCore l e c v (LiftedObservable l e la ea c v) where
  readObservable# (LiftedObservable fx) =
    relaxObservableState <$> readObservable# fx

  attachObserver# (LiftedObservable fx) callback =
    relaxObservableState <<$>> attachObserver# fx (callback . relaxObservableChange)

instance (ea :<< e, RelaxLoad la l, ObservableContainer c v, ContainerConstraint l e c v (LiftedObservable l e la ea c v)) => ToObservableT l e c v (LiftedObservable l e la ea c v) where
  toObservableT = ObservableT


type RelaxLoad :: LoadKind -> LoadKind -> Constraint
class RelaxLoad la l where
  relaxObservableChangeLoad :: ObservableChange la c v -> ObservableChange l c v
  relaxObservableStateLoad :: ObservableState la c v -> ObservableState l c v

instance RelaxLoad l l where
  relaxObservableChangeLoad = id
  relaxObservableStateLoad = id

instance {-# INCOHERENT #-} RelaxLoad l Load where
  relaxObservableChangeLoad ObservableChangeLoadingClear = ObservableChangeLoadingClear
  relaxObservableChangeLoad ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  relaxObservableChangeLoad ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  relaxObservableChangeLoad (ObservableChangeLiveUpdate update) = ObservableChangeLiveUpdate update

  relaxObservableStateLoad ObservableStateLoading = ObservableStateLoading
  relaxObservableStateLoad (ObservableStateLive result) = ObservableStateLive result

instance {-# INCOHERENT #-} RelaxLoad NoLoad l where
  relaxObservableChangeLoad (ObservableChangeLiveUpdate update) = ObservableChangeLiveUpdate update

  relaxObservableStateLoad (ObservableStateLive result) = ObservableStateLive result

relaxObservableChange ::
  forall la l ea e c v.
  (ea :<< e, RelaxLoad la l) =>
  ObservableChange la (ObservableResult ea c) v ->
  ObservableChange l (ObservableResult e c) v
relaxObservableChange change =
  relaxObservableChangeLoad (mapObservableChangeResultEx relaxEx change)

relaxObservableState ::
  forall la l ea e c v.
  (ea :<< e, RelaxLoad la l) =>
  ObservableState la (ObservableResult ea c) v -> ObservableState l (ObservableResult e c) v
relaxObservableState state =
  relaxObservableStateLoad @la @l (mapObservableStateResultEx relaxEx state)
