{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Quasar.Network.Runtime.Observable () where

import Control.Monad.Catch
import Data.Binary (Binary)
import Data.Map.Strict (Map)
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
import Quasar.Observable.Subject
import Quasar.Observable.Traversable
import Quasar.Prelude
import Quasar.Resources


-- * ObservableT instance

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, TraversableObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ())) => NetworkRootReference (ObservableT Load '[SomeException] c v) where
  type NetworkRootReferenceChannel (ObservableT Load '[SomeException] c v) = Channel () (ObservableResponse c) ObservableRequest
  provideRootReference = sendObservableReference
  receiveRootReference = receiveObservableReference

instance (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), NetworkObject v, TraversableObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ())) => NetworkObject (ObservableT Load '[SomeException] c v) where
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


-- * Implementation


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

pack :: ObservableChange Load (ObservableResult '[SomeException] c) () -> PackedChange c
pack ObservableChangeLoadingClear = PackedChangeLoadingClear
pack ObservableChangeLoadingUnchanged = PackedChangeLoadingUnchanged
pack ObservableChangeLiveUnchanged = PackedChangeLiveUnchanged
pack (ObservableChangeLiveReplace (ObservableResultEx ex)) =
  PackedChangeLiveUpdateThrow (packException ex)
pack (ObservableChangeLiveReplace (ObservableResultOk content)) =
  PackedChangeLiveUpdateReplace content
pack (ObservableChangeLiveDelta delta) =
  PackedChangeLiveUpdateDelta delta

unpack :: PackedChange c -> ObservableChange Load (ObservableResult '[SomeException] c) ()
unpack PackedChangeLoadingClear = ObservableChangeLoadingClear
unpack PackedChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
unpack PackedChangeLiveUnchanged = ObservableChangeLiveUnchanged
unpack (PackedChangeLiveUpdateThrow packedException) =
  ObservableChangeLiveReplace (ObservableResultEx (toEx (unpackException packedException)))
unpack (PackedChangeLiveUpdateReplace packedContent) =
  ObservableChangeLiveReplace (ObservableResultOk packedContent)
unpack (PackedChangeLiveUpdateDelta packedDelta) =
  ObservableChangeLiveDelta packedDelta

instance (Binary (c ()), Binary (Delta c ())) => Binary (PackedChange c)


type ObservableReference :: (Type -> Type) -> Type -> Type
data ObservableReference c v = ObservableReference {
  isAttached :: TVar Bool,
  observableDisposer :: TVar TDisposer,
  pendingChange :: TVar (PendingChange Load (ObservableResult '[SomeException] c) v),
  lastChange :: TVar (LastChange Load),
  activeObjects :: TVar (ObserverState Load (ObservableResult '[SomeException] c) Disposer),
  pendingDisposal :: TVar (Maybe Disposer)
}

sendObservableReference
  :: forall c v. (TraversableObservableContainer c, ObservableContainer c Disposer, Binary (c ()), Binary (Delta c ()), NetworkObject v)
  => ObservableT Load '[SomeException] c v
  -> Channel () (ObservableResponse c) ObservableRequest
  -> STMc NoRetry '[] (ChannelHandler ObservableRequest)
sendObservableReference observable channel = do
  isAttached <- newTVar False
  observableDisposer <- newTVar mempty
  let (pending, last) = initialPendingAndLastChange @(ObservableResult '[SomeException] c) ObservableStateLoading
  pendingChange <- newTVar pending
  lastChange <- newTVar last
  activeObjects <- newTVar ObserverStateLoadingCleared
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
        unlessM (readTVar ref.isAttached) do
          (disposer, initial) <- attachObserver# observable (upstreamObservableChanged ref)
          writeTVar ref.observableDisposer disposer
          upstreamObservableChanged ref (toReplacingChange initial)
          writeTVar ref.isAttached True
    requestCallback ref _context Stop = atomicallyC do
      disposeTDisposer =<< swapTVar ref.observableDisposer mempty
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
              liftSTMc (provideAndPackChange ref context loadingChange) >>= \case
                Just (packedChange, removedObjects) -> do
                  modifyTVar ref.pendingDisposal (Just . (<> removedObjects) . fromMaybe mempty)
                  pure packedChange
                Nothing ->
                  -- This should be an unreachable code path.
                  pure PackedChangeLoadingUnchanged

    provideAndPackChange
      :: ObservableReference c v
      -> SendMessageContext
      -> ObservableChange Load (ObservableResult '[SomeException] c) v
      -> STMc NoRetry '[] (Maybe (PackedChange c, Disposer))
    provideAndPackChange ref context change = do
      state <- readTVar ref.activeObjects
      traverseChange (provideObjectAsDisposableMessagePart context) change state >>= \case
        Nothing -> pure Nothing
        Just disposerChange -> do
          let removed = selectRemovedByChange change state
          mapM_ (writeTVar ref.activeObjects . snd) (applyObservableChange disposerChange state)
          pure (Just (pack (void disposerChange), mconcat removed))

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
    observableVar :: Subject Load '[SomeException] c v,
    deltaContextVar :: TVar (ObserverContext Load (ObservableResult '[SomeException] c))
  }

data ProxyState
  = Started
  | Stopped
  deriving stock (Eq, Show)

receiveObservableReference
  :: forall c v. (ContainerConstraint Load '[SomeException] c v (ObservableProxy c v), TraversableObservableContainer c, NetworkObject v)
  => Channel () ObservableRequest (ObservableResponse c)
  -> STMc NoRetry '[MultiplexerException] (ChannelHandler (ObservableResponse c), ObservableT Load '[SomeException] c v)
receiveObservableReference channel = do
  observableVar <- newLoadingSubject
  terminated <- newTVar False
  deltaContextVar <- newTVar ObserverContextLoadingCleared
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

  pure (callback proxy, toObservableT proxy)
  where
    callback :: ObservableProxy c v -> ReceiveMessageContext -> ObservableResponse c -> QuasarIO ()
    callback proxy context packed = do
      -- unpack proxy.deltaContextVar context packed
      mchange <- atomicallyC $ receiveChangeContents proxy.deltaContextVar context (unpack packed)
      mapM_ (apply proxy) mchange

    apply :: ObservableProxy c v -> ObservableChange Load (ObservableResult '[SomeException] c) v -> QuasarIO ()
    apply proxy change = atomically do
      unlessM (readTVar proxy.terminated) do
        changeSubject proxy.observableVar change

receiveChangeContents
  :: forall l c v. (NetworkObject v, TraversableObservableContainer c)
  => TVar (ObserverContext l c)
  -> ReceiveMessageContext
  -> ObservableChange l c ()
  -> STMc NoRetry '[MultiplexerException] (Maybe (ObservableChange l c v))
receiveChangeContents ctxVar context delta = do
  ctx <- readTVar ctxVar
  result <- traverseChangeWithContext (\() -> receiveObjectFromMessagePart @v context) delta ctx
  case result of
    Just update -> writeTVar ctxVar (updateObserverContext ctx update)
    Nothing -> pure ()
  pure result

instance (ObservableContainer c v, ContainerConstraint Load '[SomeException] c v (ObservableProxy c v)) => ToObservableT Load '[SomeException] c v (ObservableProxy c v) where
  toObservableT proxy = ObservableT proxy

instance ObservableContainer c v => IsObservableCore Load '[SomeException] c v (ObservableProxy c v) where
  readObservable# proxy = readObservable# proxy.observableVar
  attachObserver# proxy callback = attachObserver# proxy.observableVar callback
  attachEvaluatedObserver# proxy callback = attachEvaluatedObserver# proxy.observableVar callback
  -- TODO better count#/isEmpty#

instance Ord k => IsObservableMap Load '[SomeException] k v (ObservableProxy (Map k) v) where
  -- TODO


manageObservableProxy :: ObservableContainer c v => ObservableProxy c v -> QuasarIO ()
manageObservableProxy proxy = do
  -- TODO verify no other exceptions can be thrown by `channelSend`
  task `catch` \(ex :: Ex '[MultiplexerException, ChannelException]) ->
    atomically do
      writeTVar proxy.terminated True
      changeSubject proxy.observableVar (ObservableChangeLiveReplace (ObservableResultEx (toEx (ObservableProxyException (toException ex)))))
  where
    task = bracket (pure proxy.channel) disposeEventuallyIO_ \channel -> do
      forever do
        atomically $ check =<< subjectHasObservers proxy.observableVar

        channelSend channel Start

        atomically $ check . not =<< subjectHasObservers proxy.observableVar

        channelSend channel Stop
