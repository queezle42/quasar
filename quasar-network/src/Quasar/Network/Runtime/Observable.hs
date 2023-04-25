-- Contains instances for `Observable` (which is also part of the quasar framework)
{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Observable (
  ObservableState(..),
  joinNetworkObservable,
) where

import Control.Monad.Catch
import Data.Binary (Binary)
import Quasar
import Quasar.Exceptions
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
  deriving stock Show

instance Exception ObservableProxyException


data ObservableRequest
  = Start
  | Stop
  deriving stock (Eq, Show, Generic)

instance Binary ObservableRequest

data ObservableResponse
  = PackedObservableValue
  | PackedObservableLoading
  | PackedObservableNotAvailable PackedException
  deriving stock Generic

instance Binary ObservableResponse


instance NetworkObject a => NetworkRootReference (Observable (ObservableState a)) where
  type NetworkRootReferenceChannel (Observable (ObservableState a)) = Channel () ObservableResponse ObservableRequest
  sendRootReference = sendObservableReference
  receiveRootReference = receiveObservableReference

instance NetworkObject a => NetworkObject (Observable (ObservableState a)) where
  type NetworkStrategy (Observable (ObservableState a)) = NetworkRootReference


data ObservableReference a = ObservableReference {
  isLoading :: TVar Bool,
  outbox :: TVar (Maybe (ObservableState a)),
  activeDisposer :: TVar Disposer
}

sendObservableReference :: forall a. NetworkObject a => Observable (ObservableState a) -> Channel () ObservableResponse ObservableRequest -> STMc NoRetry '[] (ChannelHandler ObservableRequest)
sendObservableReference observable channel = do
  -- Bind resources lifetime to network channel
  execForeignQuasarSTMc @NoRetry channel.quasar do
    -- Initial state is defined as loading
    isLoading <- newTVar True
    outbox <- newTVar Nothing
    activeDisposer <- newTVar trivialDisposer
    let ref = ObservableReference { isLoading, outbox, activeDisposer }
    asyncSTM_ $ sendThread ref
    observeQ_ observable (callback ref)
  pure requestCallback
  where
    requestCallback :: ReceiveMessageContext -> ObservableRequest -> QuasarIO ()
    -- TODO: observe based on downstream request
    requestCallback _context Start = pure ()
    requestCallback _context Stop = pure ()
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
        sendChannelMessageDeferred_ channel payloadHook
      where
        payloadHook :: SendMessageContext -> STMc NoRetry '[AbortSend] ObservableResponse
        payloadHook context = do
          writeTVar ref.isLoading False
          swapTVar ref.outbox Nothing >>= \case
            Just (ObservableValue content) -> do
              disposer <- liftSTMc $ sendObjectAsDisposableMessagePart context content
              writeTVar ref.activeDisposer disposer
              pure PackedObservableValue

            Just (ObservableNotAvailable ex) ->
              pure (PackedObservableNotAvailable (packException ex))

            Just ObservableLoading -> throwC AbortSend
            Nothing -> unreachableCodePath

    handleDisconnect :: MonadCatch m => m () -> m ()
    handleDisconnect = handle \ChannelNotConnected -> pure ()



data ObservableProxy a =
  ObservableProxy {
    channel :: Channel () ObservableRequest ObservableResponse,
    observableVar :: ObservableVar (ObservableState a)
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference :: forall a. NetworkObject a => Channel () ObservableRequest ObservableResponse -> STMc NoRetry '[MultiplexerException] (ChannelHandler ObservableResponse, Observable (ObservableState a))
receiveObservableReference channel = do
  observableVar <- newObservableVar ObservableLoading
  let proxy = ObservableProxy {
      channel,
      observableVar
    }

  ac <- unmanagedAsyncSTM channel.quasar.exceptionSink do
    runQuasarIO channel.quasar (manageObservableProxy proxy)

  handleSTMc @NoRetry @'[FailedToAttachResource] @FailedToAttachResource (throwToExceptionSink channel.quasar.exceptionSink) do
    attachResource channel.quasar.resourceManager ac

  pure (callback proxy, toObservable proxy)
  where
    callback :: ObservableProxy a -> ReceiveMessageContext -> ObservableResponse -> QuasarIO ()
    callback proxy context PackedObservableValue = do
      value <- atomicallyC $ receiveObjectFromMessagePart context
      atomically $ writeObservableVar proxy.observableVar (ObservableValue value)
    callback proxy _context PackedObservableLoading = do
      atomically $ writeObservableVar proxy.observableVar ObservableLoading
    callback proxy _context (PackedObservableNotAvailable ex) = do
      atomically $ writeObservableVar proxy.observableVar (ObservableNotAvailable (unpackException ex))


instance NetworkObject a => ToObservable (ObservableState a) (ObservableProxy a) where
  toObservable proxy = toObservable proxy.observableVar


manageObservableProxy :: ObservableProxy a -> QuasarIO ()
manageObservableProxy proxy =
  -- TODO verify no other exceptions can be thrown by `channelSend`
  task `catch` \(ex :: Ex '[MultiplexerException, ChannelException]) ->
    atomically (writeObservableVar proxy.observableVar (ObservableNotAvailable (toException (ObservableProxyException (toException ex)))))
  where
    task = bracket (pure proxy.channel) disposeEventuallyIO_ \channel -> do
      forever do
        atomically $ check =<< observableVarHasObservers proxy.observableVar

        channelSend channel Start

        atomically $ check . not =<< observableVarHasObservers proxy.observableVar

        channelSend channel Stop
