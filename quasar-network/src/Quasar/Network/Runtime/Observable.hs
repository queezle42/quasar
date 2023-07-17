{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Quasar.Network.Runtime.Observable (
  NetworkObservableContainer(..),
) where

import Control.Monad.Catch
import Data.Binary (Binary)
import Data.Functor.Identity (Identity(..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
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
import Data.Bifunctor (first)


-- * ObservableT instance

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, NetworkObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ())) => NetworkRootReference (ObservableT Load '[SomeException] c v) where
  type NetworkRootReferenceChannel (ObservableT Load '[SomeException] c v) = Channel () (ObservableResponse c) ObservableRequest
  provideRootReference = sendObservableReference
  receiveRootReference = receiveObservableReference

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, NetworkObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ())) => NetworkObject (ObservableT Load '[SomeException] c v) where
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
  receiveRootReference channel = ObservableMap <<$>> receiveObservableReference @(Map k) @v channel

instance (Ord k, Binary k, NetworkObject v) => NetworkObject (ObservableMap Load '[SomeException] k v) where
  type NetworkStrategy (ObservableMap Load '[SomeException] k v) = NetworkRootReference


-- * Selecting removals from a delta

class (Traversable c, Functor (Delta c), forall a. ObservableContainer c a) => NetworkObservableContainer c where
  traverseDelta :: Applicative m => (v -> m a) -> Delta c v -> DeltaContext c -> m (Maybe (Delta c a))
  default traverseDelta :: (Traversable (Delta c), Applicative m) => (v -> m a) -> Delta c v -> DeltaContext c -> m (Maybe (Delta c a))
  traverseDelta fn delta _ = Just <$> traverse fn delta

  selectRemoved :: Delta c v -> c a -> [a]

instance NetworkObservableContainer Identity where
  selectRemoved _update (Identity old) = [old]

instance Ord k => NetworkObservableContainer (Map k) where
  selectRemoved (ObservableMapDelta ops) old = mapMaybe (\key -> Map.lookup key old) (Map.keys ops)

instance NetworkObservableContainer c => NetworkObservableContainer (ObservableResult '[SomeException] c) where
  traverseDelta fn delta (Just x) = traverseDelta @c fn delta x
  traverseDelta _fn _delta Nothing = pure Nothing

  selectRemoved delta (ObservableResultOk x) = selectRemoved delta x
  selectRemoved _ (ObservableResultEx _ex) = []


traverseUpdate :: forall c v a m. (Applicative m, NetworkObservableContainer c) => (v -> m a) -> ObservableUpdate c v -> Maybe (DeltaContext c) -> m (Maybe (ObservableUpdate c a, DeltaContext c))
traverseUpdate fn (ObservableUpdateReplace content) _context = do
  newContent <- traverse fn content
  pure (Just (ObservableUpdateReplace newContent, toInitialDeltaContext @c newContent))
traverseUpdate fn (ObservableUpdateDelta delta) (Just context) = do
  traverseDelta @c fn delta context <<&>> \newDelta ->
    (ObservableUpdateDelta newDelta, updateDeltaContext @c context delta)
traverseUpdate _fn (ObservableUpdateDelta _delta) Nothing = pure Nothing

selectRemovedUpdate :: NetworkObservableContainer c => ObservableUpdate c v -> c a -> [a]
selectRemovedUpdate (ObservableUpdateReplace _new) old = toList old
selectRemovedUpdate (ObservableUpdateDelta delta) old = selectRemoved delta old


-- * Implementation

provideUpdate
  :: forall c v. (NetworkObject v, NetworkObservableContainer c)
  => SendMessageContext
  -> ObservableUpdate c v
  -> Maybe (DeltaContext c)
  -> STMc NoRetry '[] (Maybe (ObservableUpdate c Disposer, ObservableUpdate c (), DeltaContext c))
provideUpdate context update ctx = do
  (\(disposerDelta, newCtx) -> (disposerDelta, void disposerDelta, newCtx)) <<$>> traverseUpdate (provideObjectAsDisposableMessagePart context) update ctx



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
  PackedChangeLiveUpdateThrow :: PackedException -> PackedChange c
  PackedChangeLiveUpdateReplace :: c () -> PackedChange c
  PackedChangeLiveUpdateDelta :: Delta c () -> PackedChange c
  deriving Generic

instance (Binary (c ()), Binary (Delta c ())) => Binary (PackedChange c)


type ObservableReference :: (Type -> Type) -> Type -> Type
data ObservableReference c v = ObservableReference {
  isAttached :: TVar Bool,
  observableDisposer :: TVar TSimpleDisposer,
  pendingChange :: TVar (PendingChange Load (ObservableResult '[SomeException] c) v),
  lastChange :: TVar (LastChange Load (ObservableResult '[SomeException] c) v),
  activeObjects :: TVar (Maybe (DeltaContext c, c Disposer)),
  pendingDisposal :: TVar (Maybe Disposer)
}

sendObservableReference
  :: forall c v. (NetworkObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ()), NetworkObject v)
  => ObservableT Load '[SomeException] c v
  -> Channel () (ObservableResponse c) ObservableRequest
  -> STMc NoRetry '[] (ChannelHandler ObservableRequest)
sendObservableReference observable channel = do
  isAttached <- newTVar False
  observableDisposer <- newTVar mempty
  let (pending, last) = initialPendingAndLastChange @(ObservableResult '[SomeException] c) ObservableStateLoading
  pendingChange <- newTVar pending
  lastChange <- newTVar last
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
      modifyTVar ref.pendingChange (updatePendingChange change)

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
              liftSTMc (provideAndPackChange ref context loadingChange) >>= \case
                Just (packedChange, removedObjects) -> do
                  modifyTVar ref.pendingDisposal (Just . (<> removedObjects) . fromMaybe mempty)
                  pure packedChange
                Nothing -> undefined

    provideAndPackChange
      :: ObservableReference c v
      -> SendMessageContext
      -> ObservableChange Load (ObservableResult '[SomeException] c) v
      -> STMc NoRetry '[] (Maybe (PackedChange c, Disposer))
    provideAndPackChange ref context change = do
      case change of
        ObservableChangeLoadingClear -> do
          readTVar ref.activeObjects >>= \case
            Nothing -> pure Nothing
            Just (_ctx, activeDisposers) -> do
              writeTVar ref.activeObjects Nothing
              pure (Just (PackedChangeLoadingClear, fold activeDisposers))
        ObservableChangeLoadingUnchanged -> pure (Just (PackedChangeLoadingUnchanged, mempty))
        ObservableChangeLiveUnchanged -> pure (Just (PackedChangeLiveUnchanged, mempty))
        ObservableChangeLiveUpdate (ObservableUpdateOk update) -> do
          (ctx, activeDisposers) <- maybe (Nothing, undefined) (first Just) <$> readTVar ref.activeObjects
          provideUpdate @c context update ctx >>= \case
            Nothing -> pure Nothing
            Just (activeObjectsUpdate, unitUpdate, newCtx) -> do
              let
                removed = fold (selectRemovedUpdate @c update activeDisposers)
                newActiveDisposers = applyObservableUpdate activeObjectsUpdate activeDisposers
                packedUnitChange = case unitUpdate of
                  (ObservableUpdateReplace unitContainer) -> PackedChangeLiveUpdateReplace unitContainer
                  (ObservableUpdateDelta unitDelta) -> PackedChangeLiveUpdateDelta unitDelta
              mapM_ (\x -> writeTVar ref.activeObjects (Just (newCtx, x))) newActiveDisposers
              pure (Just (packedUnitChange, removed))
        ObservableChangeLiveUpdate (ObservableUpdateThrow ex) -> do
          readTVar ref.activeObjects >>= \case
            Nothing -> pure Nothing
            Just (_ctx, activeDisposers) -> do
              writeTVar ref.activeObjects Nothing
              pure (Just (PackedChangeLiveUpdateThrow (packException ex), fold activeDisposers))

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

              liftSTMc (provideAndPackChange ref context change) >>= \case
                Just x -> pure x
                Nothing -> throwC AbortSend


    handleDisconnect :: MonadCatch m => m () -> m ()
    handleDisconnect = handle \ChannelNotConnected -> pure ()



data ObservableProxy c v =
  ObservableProxy {
    channel :: Channel () ObservableRequest (ObservableResponse c),
    terminated :: TVar Bool,
    observableVar :: ObservableVar Load '[SomeException] c v,
    deltaContextVar :: TVar (Maybe (DeltaContext c))
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference
  :: forall c v. (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObservableContainer c, NetworkObject v)
  => Channel () ObservableRequest (ObservableResponse c)
  -> STMc NoRetry '[MultiplexerException] (ChannelHandler (ObservableResponse c), ObservableT Load '[SomeException] c v)
receiveObservableReference channel = do
  observableVar <- newLoadingObservableVar
  terminated <- newTVar False
  deltaContextVar <- newTVar Nothing
  let proxy = ObservableProxy {
      channel,
      terminated,
      observableVar,
      deltaContextVar
    }

  ac <- unmanagedAsyncSTM channel.quasar.exceptionSink do
    runQuasarIO channel.quasar (manageObservableProxy proxy)

  handleSTMc @NoRetry @'[FailedToAttachResource] @FailedToAttachResource (throwToExceptionSink channel.quasar.exceptionSink) do
    attachResource channel.quasar.resourceManager ac

  pure (callback proxy, toObservableCore proxy)
  where
    callback :: ObservableProxy c v -> ReceiveMessageContext -> ObservableResponse c -> QuasarIO ()
    callback proxy context packed =
      mapM_ (apply proxy) =<< unpack proxy.deltaContextVar context packed

    unpack :: TVar (Maybe (DeltaContext c)) -> ReceiveMessageContext -> ObservableResponse c -> QuasarIO (Maybe (ObservableChange Load (ObservableResult '[SomeException] c) v))
    unpack var _context PackedChangeLoadingClear = do
      atomically $ writeTVar var Nothing
      pure (Just ObservableChangeLoadingClear)
    unpack _var _context PackedChangeLoadingUnchanged = pure (Just ObservableChangeLoadingUnchanged)
    unpack _var _context PackedChangeLiveUnchanged = pure (Just ObservableChangeLiveUnchanged)
    unpack var _context (PackedChangeLiveUpdateThrow packedException) = do
      atomically $ writeTVar var Nothing
      pure (Just (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultEx (toEx (unpackException packedException))))))
    unpack var context (PackedChangeLiveUpdateReplace packedContent) = do
      update <- atomicallyC $ receiveUpdate var context (ObservableUpdateReplace packedContent)
      pure (ObservableChangeLiveUpdate . ObservableUpdateOk <$> update)
    unpack var context (PackedChangeLiveUpdateDelta packedDelta) = do
      update <- atomicallyC $ receiveUpdate var context (ObservableUpdateDelta packedDelta)
      pure (ObservableChangeLiveUpdate . ObservableUpdateOk <$> update)

    apply :: ObservableProxy c v -> ObservableChange Load (ObservableResult '[SomeException] c) v -> QuasarIO ()
    apply proxy change = atomically do
      unlessM (readTVar proxy.terminated) do
        changeObservableVar proxy.observableVar change

receiveUpdate
  :: forall c v. (NetworkObject v, NetworkObservableContainer c)
  => TVar (Maybe (DeltaContext c))
  -> ReceiveMessageContext
  -> ObservableUpdate c ()
  -> STMc NoRetry '[MultiplexerException] (Maybe (ObservableUpdate c v))
receiveUpdate ctxVar context delta = do
  ctx <- readTVar ctxVar
  traverseUpdate (\() -> receiveObjectFromMessagePart @v context) delta ctx >>= \case
    Just (update, newCtx) -> do
      writeTVar ctxVar (Just newCtx)
      pure (Just update)
    Nothing -> pure Nothing

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
      changeObservableVar proxy.observableVar (ObservableChangeLiveUpdate (ObservableUpdateThrow (toEx (ObservableProxyException (toException ex)))))
  where
    task = bracket (pure proxy.channel) disposeEventuallyIO_ \channel -> do
      forever do
        atomically $ check =<< observableVarHasObservers proxy.observableVar

        channelSend channel Start

        atomically $ check . not =<< observableVarHasObservers proxy.observableVar

        channelSend channel Stop
