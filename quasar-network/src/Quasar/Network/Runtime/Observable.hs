-- Contains instances for `Observable` (which is also part of the quasar framework)
{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Observable (
  ObservableState(..),
  joinNetworkObservable,
) where

import Data.Binary (Binary)
import Control.Monad.Catch
import Quasar
import Quasar.Network.Exception
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Prelude


data ObservableState a
  = ObservableValue a
  | ObservableLoading
  | ObservableNotAvailable SomeException

instance Functor ObservableState where
  fmap f (ObservableValue x) = ObservableValue (f x)
  fmap _ ObservableLoading = ObservableLoading
  fmap _ (ObservableNotAvailable e) = ObservableNotAvailable e

instance Applicative ObservableState where
  pure x = ObservableValue x
  liftA2 f (ObservableValue x) (ObservableValue y) = ObservableValue (f x y)
  liftA2 _ ObservableLoading _ = ObservableLoading
  liftA2 _ (ObservableNotAvailable e) _ = ObservableNotAvailable e
  liftA2 _ _ ObservableLoading = ObservableLoading
  liftA2 _ _ (ObservableNotAvailable e) = ObservableNotAvailable e

instance Monad ObservableState where
  ObservableValue x >>= fy = fy x
  ObservableLoading >>= _ = ObservableLoading
  ObservableNotAvailable e >>= _ = ObservableNotAvailable e

joinNetworkObservable :: Observable (ObservableState (Observable (ObservableState a))) -> Observable (ObservableState a)
joinNetworkObservable x = x >>= \case
  ObservableValue r -> r
  ObservableLoading -> pure ObservableLoading
  ObservableNotAvailable e -> pure (ObservableNotAvailable e)


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


instance NetworkObject a => NetworkReference (Observable (ObservableState a)) where
  type NetworkReferenceChannel (Observable (ObservableState a)) = Channel (ObservableResponse a) ObservableRequest
  sendReference = sendObservableReference
  receiveReference = receiveObservableReference

instance NetworkObject a => NetworkObject (Observable (ObservableState a)) where
  type NetworkStrategy (Observable (ObservableState a)) = NetworkReference


data ObservableReference a = ObservableReference {
  isLoading :: TVar Bool,
  outbox :: TVar (Maybe (ObservableState a)),
  activeDisposer :: TVar Disposer
}

sendObservableReference :: forall a. NetworkObject a => Observable (ObservableState a) -> Channel (ObservableResponse a) ObservableRequest -> QuasarIO ()
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
    quasarAtomically $ observeQ_ observable (callback ref)
  where
    requestCallback :: ObservableRequest -> QuasarIO ()
    -- TODO: observe based on downstream request
    requestCallback Start = pure ()
    requestCallback Stop = pure ()
    callback :: ObservableReference a -> ObservableState a -> STMc NoRetry '[SomeException] ()
    callback ref state = do
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
            atomically $ writeTVar ref.activeDisposer (getDisposer objectChannel)
            pure ()
          (resources, Nothing) -> do
            [] <- pure resources.createdChannels
            pure ()
      where
        payloadHook :: STMc NoRetry '[AbortSend] (ChannelMessage (ObservableResponse a), Maybe (RawChannel -> QuasarIO ()))
        payloadHook = do
          writeTVar ref.isLoading False
          swapTVar ref.outbox Nothing >>= \case
            Just (ObservableValue content) -> do
              let (cdata, mBindObjectFn) = sendObject content
              let createChannels = maybe 0 (const 1) mBindObjectFn
              pure ((channelMessage (PackedObservableValue cdata)) { createChannels }, mBindObjectFn)

            Just (ObservableNotAvailable ex) ->
              pure (channelMessage (PackedObservableNotAvailable (packException ex)), Nothing)

            Just ObservableLoading -> throwC AbortSend
            Nothing -> unreachableCodePath

    handleDisconnect :: MonadCatch m => m () -> m ()
    handleDisconnect = handle \ChannelNotConnected -> pure ()



data ObservableProxy a =
  ObservableProxy {
    channelFuture :: Future (Channel ObservableRequest (ObservableResponse a)),
    observableVar :: ObservableVar (ObservableState a)
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference :: NetworkObject a => Future (Channel ObservableRequest (ObservableResponse a)) -> QuasarIO (Observable (ObservableState a))
receiveObservableReference channelFuture = do
  observableVar <- newObservableVarIO ObservableLoading
  let proxy = ObservableProxy {
      channelFuture,
      observableVar
    }
  -- TODO thread should be disposed with the channel, so it should optimally be attached to the channel.
  -- The current architecture doesn't permit this, which is probably a bug.
  async_ $ manageObservableProxy proxy
  pure $ toObservable proxy


instance NetworkObject a => ToObservable (ObservableState a) (ObservableProxy a) where
  toObservable proxy = toObservable proxy.observableVar


manageObservableProxy :: forall a. NetworkObject a => ObservableProxy a -> QuasarIO ()
manageObservableProxy proxy =
  task `catchAll` \ex ->
    atomically (writeObservableVar proxy.observableVar (ObservableNotAvailable (toException (ObservableProxyException ex))))
  where
    task = bracket setupChannel dispose \channel -> do
      forever do
        atomically $ check =<< observableVarHasObservers proxy.observableVar

        channelSend channel Start

        atomically $ check . not =<< observableVarHasObservers proxy.observableVar

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
      atomically $ writeObservableVar proxy.observableVar (ObservableValue content)
    callback resources PackedObservableLoading = do
      [] <- pure resources.createdChannels
      atomically $ writeObservableVar proxy.observableVar ObservableLoading
    callback resources (PackedObservableNotAvailable ex) = do
      [] <- pure resources.createdChannels
      atomically $ writeObservableVar proxy.observableVar (ObservableNotAvailable (unpackException ex))
