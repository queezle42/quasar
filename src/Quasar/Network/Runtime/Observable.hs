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
  | Once
  deriving stock (Eq, Show, Generic)
  deriving anyclass Binary

data ObservableResponse a
  = PackedObservableValue a
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock (Eq, Show, Generic)
  deriving anyclass Binary

packObservableState :: ObservableState r -> ObservableResponse r
packObservableState (ObservableValue x) = PackedObservableValue x
packObservableState ObservableLoading = PackedObservableLoading
packObservableState (ObservableNotAvailable ex) = PackedObservableNotAvailable (packException ex)

unpackObservableState :: ObservableResponse r -> ObservableState r
unpackObservableState (PackedObservableValue x) = ObservableValue x
unpackObservableState PackedObservableLoading = ObservableLoading
unpackObservableState (PackedObservableNotAvailable ex) = ObservableNotAvailable (unpackException ex)


instance NetworkObject a => NetworkReference (Observable a) where
  type NetworkReferenceChannel (Observable a) = Channel (ObservableResponse a) ObservableRequest
  sendReference = sendObservableReference
  receiveReference = receiveObservableReference

instance NetworkObject a => NetworkObject (Observable a) where
  type NetworkStrategy (Observable a) = NetworkReference


data ProxyState
  = Stopped
  | Started
  | StartRequestedWaitingForChannel
  deriving stock (Eq, Show)

data ObservableProxy a =
  ObservableProxy {
    channelFuture :: Future (Channel ObservableRequest (ObservableResponse a)),
    proxyState :: TVar ProxyState,
    observablePrim :: ObservablePrim a
  }

sendObservableReference :: NetworkObject a => Observable a -> Channel (ObservableResponse a) ObservableRequest -> QuasarIO ()
sendObservableReference observable = undefined

receiveObservableReference :: NetworkObject a => Future (Channel ObservableRequest (ObservableResponse a)) -> QuasarIO (Observable a)
receiveObservableReference channelFuture = do
  proxyState <- newTVarIO Stopped
  observablePrim <- newObservablePrimIO ObservableLoading
  let proxy = ObservableProxy {
      channelFuture,
      proxyState,
      observablePrim
    }
  async_ $ manageObservableProxy proxy
  pure $ toObservable proxy

instance NetworkObject a => IsRetrievable a (ObservableProxy a) where
  retrieve proxy = undefined


instance NetworkObject a => IsObservable a (ObservableProxy a) where
  observe proxy callback = liftQuasarSTM do
    state <- readTVar proxy.proxyState
    when (state == Stopped) undefined
    pure undefined
  pingObservable proxy = undefined


manageObservableProxy :: ObservableProxy a -> QuasarIO ()
manageObservableProxy proxy =
  (await proxy.channelFuture >>= loop)
    `catch`
      \ex -> atomically (setObservablePrim proxy.observablePrim (ObservableNotAvailable (toException (ObservableProxyException ex))))
  where
    loop channel = forever do
      atomically $ check =<< observablePrimHasObservers proxy.observablePrim

      channelSend channel Start

      atomically $ check . not =<< observablePrimHasObservers proxy.observablePrim

      channelSend channel Stop

      atomically $ setObservablePrim proxy.observablePrim ObservableLoading
    --callback (unpackObservableState -> state) = atomically $ setObservablePrim proxy.observablePrim state
