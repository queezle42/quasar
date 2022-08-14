-- Contains instances for `Observable` (which is also part of the quasar framework)
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


data ObservableProxyException = ObservableProxyException SomeException
  deriving stock (Show)
  deriving anyclass (Exception)


data ObservableRequest
  = Start
  | Stop
  deriving stock (Eq, Show, Generic)
  deriving anyclass Binary

data ObservableResponse a
  = PackedObservableValue (CData a)
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock Generic

instance NetworkObject a => Binary (ObservableResponse a)


instance NetworkObject a => NetworkReference (Observable a) where
  type NetworkReferenceChannel (Observable a) = Channel (ObservableResponse a) ObservableRequest
  sendReference = sendObservableReference
  receiveReference = receiveObservableReference

instance NetworkObject a => NetworkObject (Observable a) where
  type NetworkStrategy (Observable a) = NetworkReference


data ObservableReference a = ObservableReference {
  isLoading :: TVar Bool,
  outbox :: TVar (Maybe (ObservableState a)),
  activeDisposer :: TVar Disposer
}

data AbortSend = AbortSend
  deriving stock (Eq, Show)
  deriving anyclass Exception

sendObservableReference :: forall a. NetworkObject a => Observable a -> Channel (ObservableResponse a) ObservableRequest -> QuasarIO ()
sendObservableReference observable channel = do
  -- Bind resources lifetime to network channel
  runQuasarIO channel.quasar do
    -- Initial state is defined as loading
    isLoading <- newTVarIO True
    outbox <- newTVarIO Nothing
    activeDisposer <- newTVarIO trivialDisposer
    let ref = ObservableReference { isLoading, outbox, activeDisposer }
    channelSetSimpleHandler channel requestCallback
    async_ $ sendThread ref
    quasarAtomically $ observe_ observable (callback ref)
  where
    requestCallback :: ObservableRequest -> QuasarIO ()
    -- TODO: observe based on downstream request
    requestCallback Start = pure ()
    requestCallback Stop = pure ()
    callback :: ObservableReference a -> ObservableState a -> STM ()
    callback ref state = liftSTM do
      unlessM (readTVar ref.isLoading) do
        -- This will only happen (at most) once per sent update.
        -- Required to preserve order across multiple observables while also being able to drop intermediate values.
        handleDisconnect $ unsafeQueueChannelMessage channel PackedObservableLoading
        writeTVar ref.isLoading True
      writeTVar ref.outbox (Just state)

    sendThread :: ObservableReference a -> QuasarIO ()
    sendThread ref = handleDisconnect $ forever do
      -- Block until an update has to be sent
      atomically $ check . isJust =<< readTVar ref.outbox
      dispose =<< atomically (swapTVar ref.activeDisposer trivialDisposer)
      handle (\AbortSend -> pure ()) do
        sendChannelMessageDeferred channel payloadHook >>= \case
          (resources, Just bindObjectFn) -> do
            [objectChannel] <- pure resources.createdChannels
            bindObjectFn objectChannel
            atomically $ writeTVar ref.activeDisposer (toDisposer objectChannel)
            pure ()
          (resources, Nothing) -> do
            [] <- pure resources.createdChannels
            pure ()
      where
        payloadHook :: STM (ChannelMessage (ObservableResponse a), Maybe (RawChannel -> QuasarIO ()))
        payloadHook = do
          writeTVar ref.isLoading False
          swapTVar ref.outbox Nothing >>= \case
            Just (ObservableValue content) -> do
              let (cdata, mBindObjectFn) = sendObject content
              pure ((channelMessage (PackedObservableValue cdata)) { createChannels = 1 }, mBindObjectFn)

            Just (ObservableNotAvailable ex) ->
              pure (channelMessage (PackedObservableNotAvailable (packException ex)), Nothing)

            Just ObservableLoading -> throwM AbortSend
            Nothing -> unreachableCodePathM

    handleDisconnect :: MonadCatch m => m () -> m ()
    handleDisconnect = handle \ChannelNotConnected -> pure ()



data ObservableProxy a =
  ObservableProxy {
    channelFuture :: Future (Channel ObservableRequest (ObservableResponse a)),
    observablePrim :: ObservablePrim a
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference :: NetworkObject a => Future (Channel ObservableRequest (ObservableResponse a)) -> QuasarIO (Observable a)
receiveObservableReference channelFuture = do
  observablePrim <- newObservablePrimIO ObservableLoading
  let proxy = ObservableProxy {
      channelFuture,
      observablePrim
    }
  -- TODO thread should be disposed with the channel, so it should optimally be attached to the channel.
  -- The current architecture doesn't permit this, which is probably a bug.
  async_ $ manageObservableProxy proxy
  pure $ toObservable proxy


instance NetworkObject a => IsObservable a (ObservableProxy a) where
  attachObserver proxy = attachObserver proxy.observablePrim


manageObservableProxy :: forall a. NetworkObject a => ObservableProxy a -> QuasarIO ()
manageObservableProxy proxy =
  task `catchAll` \ex ->
    atomically (setObservablePrim proxy.observablePrim (ObservableNotAvailable (toException (ObservableProxyException ex))))
  where
    task = bracket setupChannel dispose \channel -> do
      forever do
        atomically $ check =<< observablePrimHasObservers proxy.observablePrim

        channelSend channel Start

        atomically $ check . not =<< observablePrimHasObservers proxy.observablePrim

        channelSend channel Stop

    setupChannel = do
      channel <- await proxy.channelFuture
      channelSetHandler channel callback
      pure channel

    callback :: ReceivedMessageResources -> ObservableResponse a -> QuasarIO ()
    callback resources (PackedObservableValue cdata) = do
      content <- case receiveObject cdata of
        Left content -> do
          [] <- pure resources.createdChannels
          pure content
        Right createContent -> do
          [objectChannel] <- pure resources.createdChannels
          createContent (pure objectChannel)
      atomically $ setObservablePrim proxy.observablePrim (ObservableValue content)
    callback resources PackedObservableLoading = do
      [] <- pure resources.createdChannels
      atomically $ setObservablePrim proxy.observablePrim ObservableLoading
    callback resources (PackedObservableNotAvailable ex) = do
      [] <- pure resources.createdChannels
      atomically $ setObservablePrim proxy.observablePrim (ObservableNotAvailable (unpackException ex))
