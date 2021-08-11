module Quasar.Network.Runtime.Observable (newObservableStub, observeToStream) where

import Data.Binary (Binary)
import Quasar.Awaitable
import Quasar.Core
import Quasar.Network.Runtime
import Quasar.Observable
import Quasar.Prelude

newObservableStub
  :: forall v. Binary v =>
     (forall m. MonadIO m => m (Stream Void v))
  -> (forall m. MonadIO m => m (Awaitable v))
  -> IO (Observable v)
newObservableStub startObserveRequest startRetrieveRequest = pure uncachedObservable -- TODO cache
  where
    uncachedObservable :: Observable v
    uncachedObservable = fnObservable observeFn retrieveFn
    observeFn :: (ObservableMessage v -> IO ()) -> IO Disposable
    observeFn callback = do
      stream <- startObserveRequest
      streamSetHandler stream (callback . ObservableUpdate)
      pure $ synchronousDisposable $ streamClose stream
    retrieveFn :: forall m. HasResourceManager m => m (Task v)
    retrieveFn = toTask <$> startRetrieveRequest

observeToStream :: HasResourceManager m => Observable v -> Stream v Void -> m ()
observeToStream observable stream = do
  disposable <- liftIO $ observe observable undefined
  -- TODO: dispose when the stream is closed
  undefined
