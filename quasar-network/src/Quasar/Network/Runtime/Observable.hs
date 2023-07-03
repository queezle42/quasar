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
--import Data.Set (Set)
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
import Quasar.Observable.Map
import Quasar.Observable.ObservableVar
import Quasar.Prelude
import Quasar.Resources


-- * ObservableT instance

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, NetworkObservableContainer c v, ObservableContainer c Disposer, Binary (Delta c ())) => NetworkRootReference (ObservableT Load '[SomeException] c v) where
  type NetworkRootReferenceChannel (ObservableT Load '[SomeException] c v) = Channel () (ObservableResponse c) ObservableRequest
  provideRootReference = sendObservableReference
  receiveRootReference = receiveObservableReference

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, NetworkObservableContainer c v, ObservableContainer c Disposer, Binary (Delta c ())) => NetworkObject (ObservableT Load '[SomeException] c v) where
  type NetworkStrategy (ObservableT Load '[SomeException] c v) = NetworkRootReference


-- * Instances for Observable

instance NetworkObject v => NetworkRootReference (Observable Load '[SomeException] v) where
  type NetworkRootReferenceChannel (Observable Load '[SomeException] v) = NetworkRootReferenceChannel (ObservableT Load '[SomeException] Identity v)
  provideRootReference (Observable x) = sendObservableReference (ObservableT x)
  receiveRootReference channel = Observable <<$>> receiveObservableReference channel

instance NetworkObject v => NetworkObject (Observable Load '[SomeException] v) where
  type NetworkStrategy (Observable Load '[SomeException] v) = NetworkRootReference


-- * Instances for ObservableMap

instance (Ord k, Binary k, NetworkObject v) => NetworkRootReference (ObservableMap Load '[SomeException] k v) where
  type NetworkRootReferenceChannel (ObservableMap Load '[SomeException] k v) = NetworkRootReferenceChannel (ObservableT Load '[SomeException] (Map k) v)
  provideRootReference (ObservableMap x) = sendObservableReference x
  receiveRootReference channel = do
    (handler, x) <- receiveObservableReference @(Map k) @v channel
    pure (handler, ObservableMap x)

instance (Ord k, Binary k, NetworkObject v) => NetworkObject (ObservableMap Load '[SomeException] k v) where
  type NetworkStrategy (ObservableMap Load '[SomeException] k v) = NetworkRootReference


-- * Selecting removals from a delta

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


-- * Implementation

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

type ObservableResponse c = PackedChange c

data PackedChange c where
  PackedChangeLoadingClear :: PackedChange c
  PackedChangeLoadingUnchanged :: PackedChange c
  PackedChangeLiveUnchanged :: PackedChange c
  PackedChangeLiveDeltaThrow :: PackedException -> PackedChange c
  PackedChangeLiveDeltaOk :: Delta c () -> PackedChange c
  deriving Generic

instance Binary (Delta c ()) => Binary (PackedChange c)


type ObservableReference :: (Type -> Type) -> Type -> Type
data ObservableReference c v = ObservableReference {
  isAttached :: TVar Bool,
  observableDisposer :: TVar TSimpleDisposer,
  pendingChange :: TVar (PendingChange Load (ObservableResult '[SomeException] c) v),
  lastChange :: TVar (LastChange Load (ObservableResult '[SomeException] c) v),
  activeObjects :: TVar (Maybe (c Disposer)),
  pendingDisposal :: TVar (Maybe Disposer)
}

sendObservableReference
  :: forall c v. (NetworkObservableContainer c v, ObservableContainer c Disposer, Binary (Delta c ()), NetworkObject v)
  => ObservableT Load '[SomeException] c v
  -> Channel () (ObservableResponse c) ObservableRequest
  -> STMc NoRetry '[] (ChannelHandler ObservableRequest)
sendObservableReference observable channel = do
  isAttached <- newTVar False
  observableDisposer <- newTVar mempty
  pendingChange <- newTVar (emptyPendingChange Loading)
  lastChange <- newTVar (initialLastChange Loading)
  activeObjects <- newTVar Nothing
  pendingDisposal <- newTVar Nothing
  let ref = ObservableReference{
    isAttached,
    observableDisposer,
    pendingChange,
    lastChange,
    activeObjects,
    pendingDisposal
  }

  -- Bind send thread lifetime to network channel
  execForeignQuasarSTMc @NoRetry channel.quasar do
    asyncSTM_ $ sendThread ref

  pure (requestCallback ref)
  where
    requestCallback :: ObservableReference c v -> ReceiveMessageContext -> ObservableRequest -> QuasarIO ()
    requestCallback ref _context Start = do
      atomicallyC do
        whenM (readTVar ref.isAttached) do
          (disposer, initial) <- attachObserver# observable (upstreamObservableChanged ref)
          writeTVar ref.observableDisposer disposer
          upstreamObservableChanged ref (toInitialChange initial)
          writeTVar ref.isAttached True
    requestCallback ref _context Stop = atomicallyC do
      disposeTSimpleDisposer =<< swapTVar ref.observableDisposer mempty
      upstreamObservableChanged ref ObservableChangeLoadingClear
      writeTVar ref.isAttached False

    upstreamObservableChanged :: ObservableReference c v -> ObservableChange Load (ObservableResult '[SomeException] c) v -> STMc NoRetry '[] ()
    upstreamObservableChanged ref change = do
      pendingChange <- stateTVar ref.pendingChange (dup . updatePendingChange change)
      lastChange <- readTVar ref.lastChange

      case changeFromPending Loading pendingChange lastChange of
        Nothing -> pure ()
        Just (loadingChange, pnew, lnew) -> do
          writeTVar ref.pendingChange pnew
          writeTVar ref.lastChange lnew

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
            handleDisconnect $ unsafeQueueChannelMessage channel \context -> do
              (packedChange, removedObjects) <- liftSTMc $ provideAndPackChange ref context loadingChange
              modifyTVar ref.pendingDisposal (Just . (<> removedObjects) . fromMaybe mempty)
              pure packedChange

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
      (pendingDisposal, isMessageAvailable) <- atomically do
        pendingChange <- readTVar ref.pendingChange
        lastChange <- readTVar ref.lastChange
        pendingDisposal <- swapTVar ref.pendingDisposal Nothing
        let isMessageAvailable = isJust $ changeFromPending Live pendingChange lastChange
        -- Block thread until it either has to dispose old objects or needs to
        -- send a message.
        check (isMessageAvailable || isJust pendingDisposal)
        pure (pendingDisposal, isMessageAvailable)

      mapM_ dispose pendingDisposal

      when isMessageAvailable do
        removedObjects <- handle (\AbortSend -> pure mempty) do
          sendChannelMessageDeferred channel payloadHook

        dispose removedObjects
      where
        payloadHook :: SendMessageContext -> STMc NoRetry '[AbortSend] (ObservableResponse c, Disposer)
        payloadHook context = do
          pendingChange <- readTVar ref.pendingChange
          lastChange <- readTVar ref.lastChange
          case changeFromPending Live pendingChange lastChange of
            Nothing -> throwC AbortSend
            Just (change, pnew, lnew) -> do
              writeTVar ref.pendingChange pnew
              writeTVar ref.lastChange lnew

              (packedChange, removedObjects) <- liftSTMc $ provideAndPackChange ref context change
              pure (packedChange, removedObjects)


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
  :: forall c v. (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObservableContainer c v, NetworkObject v)
  => Channel () ObservableRequest (ObservableResponse c)
  -> STMc NoRetry '[MultiplexerException] (ChannelHandler (ObservableResponse c), ObservableT Load '[SomeException] c v)
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

  pure (callback proxy, toObservableCore proxy)
  where
    callback :: ObservableProxy c v -> ReceiveMessageContext -> ObservableResponse c -> QuasarIO ()
    callback proxy _context PackedChangeLoadingClear = apply proxy ObservableChangeLoadingClear
    callback proxy _context PackedChangeLoadingUnchanged = apply proxy ObservableChangeLoadingUnchanged
    callback proxy _context PackedChangeLiveUnchanged = apply proxy ObservableChangeLiveUnchanged
    callback proxy _context (PackedChangeLiveDeltaThrow packedException) =
      apply proxy (ObservableChangeLiveDeltaThrow (toEx (unpackException packedException)))
    callback proxy context (PackedChangeLiveDeltaOk packedDelta) = do
      delta <- atomicallyC $ receiveDelta @c context packedDelta
      apply proxy (ObservableChangeLiveDeltaOk delta)

    apply :: ObservableProxy c v -> ObservableChange Load (ObservableResult '[SomeException] c) v -> QuasarIO ()
    apply proxy change = atomically do
      unlessM (readTVar proxy.terminated) do
        changeObservableVar proxy.observableVar change

instance ContainerConstraint Load '[SomeException] c v (ObservableProxy c v) => ToObservableT Load '[SomeException] c v (ObservableProxy c v) where
  toObservableCore proxy = ObservableT proxy

instance IsObservableCore Load '[SomeException] c v (ObservableProxy c v) where
  readObservable# = absurdLoad
  attachObserver# proxy callback = attachObserver# proxy.observableVar callback
  attachEvaluatedObserver# proxy callback = attachEvaluatedObserver# proxy.observableVar callback
  -- TODO better count#/isEmpty#

instance IsObservableMap Load '[SomeException] k v (ObservableProxy (Map k) v) where
  -- TODO


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
