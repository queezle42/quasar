{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.Lift (
  liftObservableT,
  liftObservable,

  -- * Operation type
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


type RelaxLoad :: LoadKind -> LoadKind -> Constraint
class RelaxLoad la l where
  relaxObservableChange :: ea :<< e => ObservableChange la (ObservableResult ea c) v -> ObservableChange l (ObservableResult e c) v
  relaxObservableState :: ea :<< e => ObservableState la (ObservableResult ea c) v -> ObservableState l (ObservableResult e c) v

instance RelaxLoad l l where
  relaxObservableChange ObservableChangeLoadingClear = ObservableChangeLoadingClear
  relaxObservableChange ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  relaxObservableChange ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx ex))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx (relaxEx ex)))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateDelta delta)) = ObservableChangeLiveUpdate (ObservableUpdateDelta delta)

  relaxObservableState ObservableStateLoading = ObservableStateLoading
  relaxObservableState (ObservableStateLive (ObservableResultOk ok)) = ObservableStateLive (ObservableResultOk ok)
  relaxObservableState (ObservableStateLive (ObservableResultEx ex)) = ObservableStateLive (ObservableResultEx (relaxEx ex))

instance {-# INCOHERENT #-} RelaxLoad l Load where
  relaxObservableChange ObservableChangeLoadingClear = ObservableChangeLoadingClear
  relaxObservableChange ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  relaxObservableChange ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx ex))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx (relaxEx ex)))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateDelta delta)) = ObservableChangeLiveUpdate (ObservableUpdateDelta delta)

  relaxObservableState ObservableStateLoading = ObservableStateLoading
  relaxObservableState (ObservableStateLive (ObservableResultOk ok)) = ObservableStateLive (ObservableResultOk ok)
  relaxObservableState (ObservableStateLive (ObservableResultEx ex)) = ObservableStateLive (ObservableResultEx (relaxEx ex))

instance {-# INCOHERENT #-} RelaxLoad NoLoad l where
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk content))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx ex))) = ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx (relaxEx ex)))
  relaxObservableChange (ObservableChangeLiveUpdate (ObservableUpdateDelta delta)) = ObservableChangeLiveUpdate (ObservableUpdateDelta delta)

  relaxObservableState (ObservableStateLive (ObservableResultOk ok)) = ObservableStateLive (ObservableResultOk ok)
  relaxObservableState (ObservableStateLive (ObservableResultEx ex)) = ObservableStateLive (ObservableResultEx (relaxEx ex))



newtype LiftedObservable l e la ea c v = LiftedObservable (ObservableT la ea c v)

instance (ea :<< e, RelaxLoad la l, ObservableContainer c v) => IsObservableCore l e c v (LiftedObservable l e la ea c v) where
  readObservable# (LiftedObservable fx) = undefined

  attachObserver# (LiftedObservable fx) callback =
    relaxObservableState <<$>> attachObserver# fx (callback . relaxObservableChange)

instance (ea :<< e, RelaxLoad la l, ObservableContainer c v, ContainerConstraint l e c v (LiftedObservable l e la ea c v)) => ToObservableT l e c v (LiftedObservable l e la ea c v) where
  toObservableT = ObservableT
