module Quasar.Network.Runtime.Observable () where

import Quasar.Network.Runtime
import Quasar.Core
import Quasar.Observable
import Quasar.Prelude

newNetworkObservable
  :: ((ObservableMessage v -> IO ()) -> IO Disposable)
  -> (forall m. HasResourceManager m => m (Task v))
  -> IO (Observable v)
newNetworkObservable observeFn retrieveFn = pure $ fnObservable observeFn retrieveFn
