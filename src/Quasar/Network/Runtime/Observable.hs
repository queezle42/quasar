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


instance NetworkObject a => NetworkReference (Observable a) where
  type ConstructorData (Observable a) = ()
  type NetworkReferenceChannel (Observable a) = Stream a Bool
  sendReference :: Observable a -> ((), Stream a Bool -> QuasarIO ())
  sendReference observable = ((), undefined)
  receiveReference :: ConstructorData (Observable a) -> Stream Bool a -> QuasarIO (Observable a)
  receiveReference () channel = undefined

instance NetworkObject a => NetworkObject (Observable a) where
  type NetworkStrategy (Observable a) = NetworkReference


data PackedObservableState a
  = PackedObservableValue a
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Binary)

packObservableState :: ObservableState r -> PackedObservableState r
packObservableState (ObservableValue x) = PackedObservableValue x
packObservableState ObservableLoading = PackedObservableLoading
packObservableState (ObservableNotAvailable ex) = PackedObservableNotAvailable (packException ex)

unpackObservableState :: PackedObservableState r -> ObservableState r
unpackObservableState (PackedObservableValue x) = ObservableValue x
unpackObservableState PackedObservableLoading = ObservableLoading
unpackObservableState (PackedObservableNotAvailable ex) = ObservableNotAvailable (unpackException ex)


data ObservableClient a =
  ObservableClient {
    quasar :: Quasar,
    beginRetrieve :: IO (Future a),
    createObservableStream :: IO (Stream Void (PackedObservableState a)),
    observablePrim :: ObservablePrim a,
    activeStreamVar :: TVar (Maybe (Stream Void (PackedObservableState a)))
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
  -> IO (Stream Void (PackedObservableState a))
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
observeToStream :: forall a. Binary a => Observable a -> Stream (PackedObservableState a) Void -> QuasarIO ()
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
        payloadHook :: STM (PackedObservableState a)
        payloadHook = do
          writeTVar isLoading False
          swapTVar outbox Nothing >>= \case
            Just state -> pure $ packObservableState state
            Nothing -> unreachableCodePathM
