-- Contains the network instances for `Observable` (from the same family of libraries)
{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Observable (
) where

import Data.Binary (Binary)
import Control.Monad.Catch
import Quasar
import Quasar.Network.Exception
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Prelude


data ObservableRequest
  = Start
  | Stop

data ObservableResponse a
  = PackedObservableValue a
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Binary)

packObservableState :: ObservableState r -> ObservableResponse r
packObservableState (ObservableValue x) = PackedObservableValue x
packObservableState ObservableLoading = PackedObservableLoading
packObservableState (ObservableNotAvailable ex) = PackedObservableNotAvailable (packException ex)

unpackObservableState :: ObservableResponse r -> ObservableState r
unpackObservableState (PackedObservableValue x) = ObservableValue x
unpackObservableState PackedObservableLoading = ObservableLoading
unpackObservableState (PackedObservableNotAvailable ex) = ObservableNotAvailable (unpackException ex)


instance NetworkObject a => NetworkReference (Observable a) where
  type NetworkReferenceChannel (Observable a) = Stream (ObservableResponse a) ObservableRequest
  sendReference = sendObservableReference
  receiveReference = receiveObservableReference

instance NetworkObject a => NetworkObject (Observable a) where
  type NetworkStrategy (Observable a) = NetworkReference


data ProxyState
  = Stopped
  | Started
  | StartRequestedWaitingForChannel

data ObservableProxy a =
  ObservableProxy {
    channelFuture :: Future (Stream ObservableRequest (ObservableResponse a)),
    proxyState :: TVar ProxyState,
    prim :: ObservablePrim a
  }

sendObservableReference :: NetworkObject a => Observable a -> Stream (ObservableResponse a) ObservableRequest -> QuasarIO ()
sendObservableReference observable = undefined

receiveObservableReference :: NetworkObject a => Future (Stream ObservableRequest (ObservableResponse a)) -> QuasarIO (Observable a)
receiveObservableReference channelFuture = liftIO do
  proxyState <- newTVarIO Stopped
  prim <- newObservablePrimIO ObservableLoading
  pure $ toObservable $
    ObservableProxy {
      channelFuture,
      proxyState,
      prim
    }

instance NetworkObject a => IsRetrievable a (ObservableProxy a) where
  retrieve proxy = undefined


instance NetworkObject a => IsObservable a (ObservableProxy a) where
  observe proxy = undefined
  pingObservable proxy = undefined






-- * Old code

data ObservableClient a =
  ObservableClient {
    quasar :: Quasar,
    beginRetrieve :: IO (Future a),
    createObservableStream :: IO (Stream Void (ObservableResponse a)),
    observablePrim :: ObservablePrim a,
    activeStreamVar :: TVar (Maybe (Stream Void (ObservableResponse a)))
  }

instance IsRetrievable a (ObservableClient a) where
  -- TODO use withResourceScope to abort on async exception (once aborting requests is supported by the code generator)
  retrieve client = liftIO $ client.beginRetrieve >>= await

instance IsObservable a (ObservableClient a) where
  observe client callback = liftQuasarSTM do
    sub <- observe client.observablePrim callback
    -- Register to clients quasar as well to ensure observers are unsubscribed when the client thread is cancelled
    runQuasarSTM client.quasar $ registerResource sub
    pure sub
  pingObservable = undefined


-- | Should be used in generated code (not implemented yet). Has to be run in context of the parent streams `Quasar`.
newObservableClient
  :: forall a. Binary a
  => IO (Future a)
  -> IO (Stream Void (ObservableResponse a))
  -> QuasarIO (Observable a)
newObservableClient beginRetrieve createObservableStream = do
  quasar <- askQuasar
  observablePrim <- newObservablePrimIO ObservableLoading
  activeStreamVar <- newTVarIO Nothing
  let client = ObservableClient {
    quasar,
    beginRetrieve,
    createObservableStream,
    observablePrim,
    activeStreamVar
  }
  async_ $ manageObservableClient client
  pure $ toObservable client

manageObservableClient :: Binary a => ObservableClient a -> QuasarIO ()
manageObservableClient ObservableClient{createObservableStream, observablePrim, activeStreamVar} = mask_ $ forever do
  atomically $ check =<< observablePrimHasObservers observablePrim

  stream <- liftIO createObservableStream
  streamSetHandler stream handler
  atomically $ writeTVar activeStreamVar (Just stream)

  atomically $ check . not =<< observablePrimHasObservers observablePrim
  mapM_ dispose =<< atomically (swapTVar activeStreamVar Nothing)
  atomically $ setObservablePrim observablePrim ObservableLoading
  where
    handler (unpackObservableState -> state) = atomically $ setObservablePrim observablePrim state

-- | Used in generated code to call `retrieve`.
callRetrieve :: Observable a -> QuasarIO (Future a)
-- TODO LATER rewrite `retrieve` to keep backpressure across multiple hops
callRetrieve x = toFuture <$> async (retrieve x)

-- | Used in generated code to call `observe`.
observeToStream :: forall a. Binary a => Observable a -> Stream (ObservableResponse a) Void -> QuasarIO ()
observeToStream observable stream = do
  runQuasarIO (streamQuasar stream) do
    -- Initial state is defined as loading, no extra message has to be sent
    isLoading <- newTVarIO True
    outbox <- newTVarIO Nothing
    async_ $ liftIO $ sendThread isLoading outbox
    quasarAtomically $ observe_ observable (callback isLoading outbox)

  where
    callback :: TVar Bool -> TVar (Maybe (ObservableState a)) -> ObservableCallback a
    callback isLoading outbox state = liftSTM do
      unlessM (readTVar isLoading) do
        unsafeQueueStreamMessage stream PackedObservableLoading
        writeTVar isLoading True
      writeTVar outbox (Just state)

    sendThread :: TVar Bool -> TVar (Maybe (ObservableState a)) -> IO ()
    sendThread isLoading outbox = forever do
      atomically $ check . isJust =<< readTVar outbox
      catch
        (streamSendDeferred stream payloadHook)
        \ChannelNotConnected -> pure ()
      where
        payloadHook :: STM (ObservableResponse a)
        payloadHook = do
          writeTVar isLoading False
          swapTVar outbox Nothing >>= \case
            Just state -> pure $ packObservableState state
            Nothing -> unreachableCodePathM
