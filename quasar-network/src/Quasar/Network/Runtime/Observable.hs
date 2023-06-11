{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Quasar.Network.Runtime.Observable (
  NetworkObservableContainer(..),
) where

import Control.Monad.Catch
import Data.Binary (Binary)
import Data.Functor.Identity (Identity(..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Quasar.Async
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.MonadQuasar.Misc
import Quasar.Network.Channel
import Quasar.Network.Exception
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime.Class
import Quasar.Network.Runtime.Generic () -- Instances are part of Quasar.Network.Runtime, but that would be an import loop.
import Quasar.Observable.Core
import Quasar.Observable.ObservableVar
import Quasar.Prelude
import Quasar.Resources


class (NetworkObservableContainer (NetworkContainer c v) (NetworkValue c v), ObservableContainer (NetworkContainer c v) Disposer, Binary (Delta (NetworkContainer c v) ()), NetworkObject (NetworkValue c v)) => NetworkObservable c v where
  type NetworkContainer c v :: Type -> Type
  type NetworkValue c v
  toNetworkObservable
    :: Observable Load '[SomeException] c v
    -> Observable Load '[SomeException] (NetworkContainer c v) (NetworkValue c v)
  fromNetworkObservable
    :: Observable Load '[SomeException] (NetworkContainer c v) (NetworkValue c v)
    -> Observable Load '[SomeException] c v

instance NetworkObject v => NetworkObservable Identity v where
  type NetworkContainer Identity v = Identity
  type NetworkValue Identity v = v
  toNetworkObservable = id
  fromNetworkObservable = id

instance (Ord v, Binary v) => NetworkObservable Set v where
  type NetworkContainer Set v = Map v
  type NetworkValue Set v = ()
  toNetworkObservable = undefined
  fromNetworkObservable = undefined



class (Foldable c, Traversable (Delta c), ObservableContainer c v) => NetworkObservableContainer c v where
  selectRemoved :: Delta c v -> c a -> [a]

instance NetworkObservableContainer Identity v where
  selectRemoved _delta (Identity old) = [old]

instance Ord k => NetworkObservableContainer (Map k) v where
  selectRemoved (ObservableMapReplace _) old = toList old
  selectRemoved (ObservableMapUpdate ops) old = mapMaybe (\key -> Map.lookup key old) (Map.keys ops)

instance NetworkObservableContainer c v => NetworkObservableContainer (ObservableResult '[SomeException] c) v where
  selectRemoved (ObservableResultDeltaOk delta) (ObservableResultOk x) = selectRemoved delta x
  selectRemoved (ObservableResultDeltaThrow _ex) (ObservableResultOk x) = toList x
  selectRemoved _ (ObservableResultEx _ex) = []


provideDelta
  :: forall c v. (NetworkObject v, NetworkObservableContainer c v)
  => SendMessageContext
  -> Delta c v
  -> STMc NoRetry '[] (Delta c Disposer, Delta c ())
provideDelta context delta = do
  disposerDelta <- traverse (provideObjectAsDisposableMessagePart context) delta
  pure (disposerDelta, void disposerDelta)

receiveDelta
  :: forall c v. (NetworkObject v, NetworkObservableContainer c v)
  => ReceiveMessageContext
  -> Delta c ()
  -> STMc NoRetry '[MultiplexerException] (Delta c v)
receiveDelta context delta = traverse (\() -> receiveObjectFromMessagePart context) delta



newtype ObservableProxyException = ObservableProxyException SomeException
  deriving stock Show

instance Exception ObservableProxyException


data ObservableRequest
  = Start
  | Stop
  deriving stock (Eq, Show, Generic)

instance Binary ObservableRequest

type ObservableResponse c = (Final, PackedChange c)

data PackedChange c where
  PackedChangeLoadingClear :: PackedChange c
  PackedChangeLoadingUnchanged :: PackedChange c
  PackedChangeLiveUnchanged :: PackedChange c
  PackedChangeLiveDeltaThrow :: PackedException -> PackedChange c
  PackedChangeLiveDeltaOk :: Delta c () -> PackedChange c
  deriving Generic

instance Binary (Delta c ()) => Binary (PackedChange c)


instance NetworkObservable c v => NetworkRootReference (Observable Load '[SomeException] c v) where
  type NetworkRootReferenceChannel (Observable Load '[SomeException] c v) = Channel () (ObservableResponse (NetworkContainer c v)) ObservableRequest
  provideRootReference = sendObservableReference . toNetworkObservable
  receiveRootReference = fmap3 fromNetworkObservable receiveObservableReference

instance NetworkObservable c v => NetworkObject (Observable Load '[SomeException] c v) where
  type NetworkStrategy (Observable Load '[SomeException] c v) = NetworkRootReference


type ObservableReference :: (Type -> Type) -> Type -> Type
data ObservableReference c v = ObservableReference {
  isAttached :: TVar Bool,
  observableDisposer :: TVar TSimpleDisposer,
  pendingChange :: TVar (PendingChange Load (ObservableResult '[SomeException] c) v),
  lastChange :: TVar (LastChange Load (ObservableResult '[SomeException] c) v),
  pendingFinal :: TVar Final,
  activeObjects :: TVar (Maybe (c Disposer))
}

sendObservableReference
  :: forall c v. (NetworkObservableContainer c v, ObservableContainer c Disposer, Binary (Delta c ()), NetworkObject v)
  => Observable Load '[SomeException] c v
  -> Channel () (ObservableResponse c) ObservableRequest
  -> STMc NoRetry '[] (ChannelHandler ObservableRequest)
sendObservableReference observable channel = do
  isAttached <- newTVar False
  observableDisposer <- newTVar mempty
  pendingChange <- newTVar (emptyPendingChange Loading)
  pendingFinal <- newTVar False
  lastChange <- newTVar LastChangeLoadingCleared
  activeObjects <- newTVar Nothing
  let ref = ObservableReference{isAttached, observableDisposer, pendingChange, lastChange, pendingFinal, activeObjects}

  -- Bind send thread lifetime to network channel
  execForeignQuasarSTMc @NoRetry channel.quasar do
    asyncSTM_ $ sendThread ref

  pure (requestCallback ref)
  where
    requestCallback :: ObservableReference c v -> ReceiveMessageContext -> ObservableRequest -> QuasarIO ()
    requestCallback ref _context Start = do
      atomicallyC do
        whenM (readTVar ref.isAttached) do
          (disposer, final, initial) <- attachObserver observable (upstreamObservableChanged ref)
          writeTVar ref.observableDisposer disposer
          upstreamObservableChanged ref final (toInitialChange initial)
          writeTVar ref.isAttached True
    requestCallback ref _context Stop = atomicallyC do
      disposeTSimpleDisposer =<< swapTVar ref.observableDisposer mempty
      -- TODO what if we already sent a final?
      upstreamObservableChanged ref False ObservableChangeLoadingClear
      writeTVar ref.isAttached False

    upstreamObservableChanged :: ObservableReference c v -> Final -> ObservableChange Load (ObservableResult '[SomeException] c) v -> STMc NoRetry '[] ()
    upstreamObservableChanged ref final change = do
      pendingChange <- stateTVar ref.pendingChange (dup . updatePendingChange change)
      lastChange <- readTVar ref.lastChange
      writeTVar ref.pendingFinal final

      case changeFromPending pendingChange lastChange of
        Nothing -> pure ()
        Just (ObservableChangeLoadingClear, loadingLastChange, loadingPendingChange) -> do
          writeTVar ref.pendingChange loadingPendingChange
          writeTVar ref.lastChange loadingLastChange
          sendChangeImmediately final PackedChangeLoadingClear
          -- Dispose active objects. This us usually handled by
          -- `provideAndPackChange`, but that can't be used since it requires a
          -- `SendMessageContext` because it also attaches `NetworkObject`s to
          -- the current message.
          activeObjects <- swapTVar ref.activeObjects Nothing
          mapM_ (mapM_ disposeEventually . toList) activeObjects
        Just (ObservableChangeLoadingUnchanged, loadingLastChange, loadingPendingChange) -> do
          writeTVar ref.pendingChange loadingPendingChange
          writeTVar ref.lastChange loadingLastChange
          sendChangeImmediately final PackedChangeLoadingUnchanged
        Just (ObservableChangeLive, _, _) -> do
          case lastChange of
            LastChangeLive -> do
              writeTVar ref.lastChange LastChangeLoading
              sendChangeImmediately False PackedChangeLoadingUnchanged
            _ -> pure ()

    sendChangeImmediately
      :: Final
      -> PackedChange c
      -> STMc NoRetry '[] ()
    sendChangeImmediately final packedChange = do
      -- unsafeQueueChannelMessage forces a message to be queued. To ensure
      -- network message scheduling fairness this will only happen at most twice
      -- (LoadingUnchanged and/or LoadingClear) per sent `Live` change.
      -- Forcing a message to be queued without waiting is required to preserve
      -- order across multiple observables (while also being able to drop
      -- intermediate values from the network stream).

      -- Disconnects are handled as a no-op. Other potential exceptions would be
      -- parse- and remote exceptions, which can't be handled here so they are
      -- passed up the channel tree. This will terminate the connection, unless
      -- the exceptions are handled explicitly somewhere else in the tree.
      handleAllSTMc @NoRetry @'[SomeException] (throwToExceptionSink channel.quasar.exceptionSink) do
        handleDisconnect $ unsafeQueueChannelMessage channel (final, packedChange)

    provideAndPackChange
      :: ObservableReference c v
      -> SendMessageContext
      -> ObservableChange Load (ObservableResult '[SomeException] c) v
      -> STMc NoRetry '[] (PackedChange c, Disposer)
    provideAndPackChange ref context change = do
      maybeActiveObjects <- readTVar ref.activeObjects
      case change of
        ObservableChangeLoadingClear -> do
          pure (PackedChangeLoadingClear, foldMap fold maybeActiveObjects)
        ObservableChangeLoadingUnchanged -> pure (PackedChangeLoadingUnchanged, mempty)
        ObservableChangeLiveUnchanged -> pure (PackedChangeLiveUnchanged, mempty)
        ObservableChangeLiveDeltaOk delta -> do
          (activeObjectsDelta, packedDelta) <- provideDelta @c context delta
          let
            newActiveObjects =
              case maybeActiveObjects of
                Just activeObjects -> applyDelta @c activeObjectsDelta activeObjects
                Nothing -> initializeFromDelta activeObjectsDelta
            removedObjects = fold (foldMap (selectRemoved @c delta) maybeActiveObjects)
          writeTVar ref.activeObjects (Just newActiveObjects)
          pure (PackedChangeLiveDeltaOk packedDelta, removedObjects)
        ObservableChangeLiveDeltaThrow ex -> do
          pure (PackedChangeLiveDeltaThrow (packException ex), foldMap fold maybeActiveObjects)

    sendThread :: ObservableReference c v -> QuasarIO ()
    sendThread ref = handleDisconnect $ forever do
      -- Block until an update has to be sent
      atomically do
        pendingChange <- readTVar ref.pendingChange
        lastChange <- readTVar ref.lastChange
        check $ isJust $ changeFromPending pendingChange lastChange


      removedObjects <- handle (\AbortSend -> pure mempty) do
        sendChannelMessageDeferred channel payloadHook

      dispose removedObjects
      where
        payloadHook :: SendMessageContext -> STMc NoRetry '[AbortSend] (ObservableResponse c, Disposer)
        payloadHook context = do
          pendingChange <- readTVar ref.pendingChange
          lastChange <- readTVar ref.lastChange
          final <- readTVar ref.pendingFinal
          case changeFromPending pendingChange lastChange of
            Nothing -> throwC AbortSend
            Just (change, lnew, pnew) -> do
              writeTVar ref.lastChange lnew
              writeTVar ref.pendingChange pnew

              (packedChange, removedObjects) <- liftSTMc $ provideAndPackChange ref context change
              pure ((final, packedChange), removedObjects)


    handleDisconnect :: MonadCatch m => m () -> m ()
    handleDisconnect = handle \ChannelNotConnected -> pure ()



data ObservableProxy c v =
  ObservableProxy {
    channel :: Channel () ObservableRequest (ObservableResponse c),
    terminated :: TVar Bool,
    observableVar :: ObservableVar Load '[SomeException] c v
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference
  :: forall c v. (NetworkObservableContainer c v, NetworkObject v)
  => Channel () ObservableRequest (ObservableResponse c)
  -> STMc NoRetry '[MultiplexerException] (ChannelHandler (ObservableResponse c), Observable Load '[SomeException] c v)
receiveObservableReference channel = do
  observableVar <- newLoadingObservableVar
  terminated <- newTVar False
  let proxy = ObservableProxy {
      channel,
      terminated,
      observableVar
    }

  ac <- unmanagedAsyncSTM channel.quasar.exceptionSink do
    runQuasarIO channel.quasar (manageObservableProxy proxy)

  handleSTMc @NoRetry @'[FailedToAttachResource] @FailedToAttachResource (throwToExceptionSink channel.quasar.exceptionSink) do
    attachResource channel.quasar.resourceManager ac

  pure (callback proxy, toObservable proxy)
  where
    callback :: ObservableProxy c v -> ReceiveMessageContext -> ObservableResponse c -> QuasarIO ()
    -- TODO handle final?
    callback proxy _context (_final, PackedChangeLoadingClear) = apply proxy ObservableChangeLoadingClear
    callback proxy _context (_final, PackedChangeLoadingUnchanged) = apply proxy ObservableChangeLoadingUnchanged
    callback proxy _context (_final, PackedChangeLiveUnchanged) = apply proxy ObservableChangeLiveUnchanged
    callback proxy _context (_final, PackedChangeLiveDeltaThrow packedException) =
      apply proxy (ObservableChangeLiveDeltaThrow (toEx (unpackException packedException)))
    callback proxy context (_final, PackedChangeLiveDeltaOk packedDelta) = do
      delta <- atomicallyC $ receiveDelta @c context packedDelta
      apply proxy (ObservableChangeLiveDeltaOk delta)

    apply :: ObservableProxy c v -> ObservableChange Load (ObservableResult '[SomeException] c) v -> QuasarIO ()
    apply proxy change = atomically do
      unlessM (readTVar proxy.terminated) do
        changeObservableVar proxy.observableVar change


instance (NetworkObject v, ObservableContainer c v) => ToObservable Load '[SomeException] c v (ObservableProxy c v) where
  toObservable proxy = toObservable proxy.observableVar


manageObservableProxy :: ObservableContainer c v => ObservableProxy c v -> QuasarIO ()
manageObservableProxy proxy = do
  -- TODO verify no other exceptions can be thrown by `channelSend`
  task `catch` \(ex :: Ex '[MultiplexerException, ChannelException]) ->
    atomically do
      writeTVar proxy.terminated True
      changeObservableVar proxy.observableVar (ObservableChangeLiveDeltaThrow (toEx (ObservableProxyException (toException ex))))
  where
    task = bracket (pure proxy.channel) disposeEventuallyIO_ \channel -> do
      forever do
        atomically $ check =<< observableVarHasObservers proxy.observableVar

        channelSend channel Start

        atomically $ check . not =<< observableVarHasObservers proxy.observableVar

        channelSend channel Stop
