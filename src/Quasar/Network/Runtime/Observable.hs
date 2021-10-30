module Quasar.Network.Runtime.Observable (
  PackedObservableMessage,
  newObservableStub,
  observeToStream,
) where

import Data.Binary (Binary)
import Control.Monad.Catch
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Exception
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Observable
import Quasar.Prelude
import Quasar.ResourceManager

data PackedObservableMessage v
  = PackedObservableUpdate v
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Binary)

packObservableMessage :: ObservableMessage r -> PackedObservableMessage r
packObservableMessage (ObservableUpdate x) = PackedObservableUpdate x
packObservableMessage (ObservableLoading) = PackedObservableLoading
packObservableMessage (ObservableNotAvailable ex) = PackedObservableNotAvailable (packException ex)

unpackObservableMessage :: PackedObservableMessage r -> ObservableMessage r
unpackObservableMessage (PackedObservableUpdate x) = ObservableUpdate x
unpackObservableMessage (PackedObservableLoading) = ObservableLoading
unpackObservableMessage (PackedObservableNotAvailable ex) = ObservableNotAvailable (unpackException ex)

newObservableStub
  :: forall v. Binary v
  => (forall m. MonadIO m => m (Awaitable v))
  -> (forall m. MonadIO m => m (Stream Void (PackedObservableMessage v)))
  -> IO (Observable v)
newObservableStub startRetrieveRequest startObserveRequest = pure uncachedObservable -- TODO cache
  where
    uncachedObservable :: Observable v
    uncachedObservable = fnObservable observeFn retrieveFn
    observeFn :: (ObservableMessage v -> ResourceManagerIO ()) -> ResourceManagerIO ()
    observeFn callback =
      registerNewResource_ do
        -- TODO send updates about the connection status
        stream <- startObserveRequest
        resourceManager <- askResourceManager
        streamSetHandler stream (handleByResourceManager resourceManager . callback . unpackObservableMessage)
        pure $ toDisposable stream
    retrieveFn :: ResourceManagerIO (Awaitable v)
    retrieveFn = startRetrieveRequest

observeToStream :: (Binary v, MonadAsync m) => Observable v -> Stream (PackedObservableMessage v) Void -> m ()
observeToStream observable stream = do
  localResourceManager stream do
    observe observable \msg -> do
      catch
        -- TODO streamSend is blocking, but the callback should return immediately
        do streamSend stream $ packObservableMessage msg
        \ChannelNotConnected -> pure ()
