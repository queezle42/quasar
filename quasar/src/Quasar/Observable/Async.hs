module Quasar.Observable.Async (
  asyncMapObservable,
  asyncMapObservableSTM,
) where

import Quasar.Observable.Core
import Quasar.Prelude


data AsyncMapObservable canLoad exceptions v = forall va. AsyncMapObservable (va -> IO v) (Observable canLoad exceptions va)

asyncMapObservable :: MonadIO m => (v -> IO va) -> Observable canLoad exceptions v -> m (Observable canLoad exceptions va)
asyncMapObservable fn observable = undefined

asyncMapObservableSTM :: MonadSTMc NoRetry '[] m => (v -> IO va) -> Observable canLoad exceptions v -> m (Observable canLoad exceptions va)
asyncMapObservableSTM = undefined
