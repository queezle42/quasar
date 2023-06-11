module Quasar.Observable.Async (
  asyncMapObservable,
  asyncMapObservableSTM,
) where

import Quasar.Observable.Core
import Quasar.Prelude


data AsyncMapObservable canLoad exceptions c v = forall ca va. AsyncMapObservable (ca va -> IO (c v)) (Observable canLoad exceptions ca va)

asyncMapObservable :: MonadIO m => (c v -> IO (ca va)) -> Observable canLoad exceptions c v -> m (Observable canLoad exceptions ca va)
asyncMapObservable fn observable = undefined

asyncMapObservableSTM :: MonadSTMc NoRetry '[] m => (c v -> IO (ca va)) -> Observable canLoad exceptions c v -> m (Observable canLoad exceptions ca va)
asyncMapObservableSTM = undefined
