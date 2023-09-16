module Quasar.Network.Client (
  -- * Client
  Client(..),
  withClientTCP,
  newClientTCP,
  withClientUnix,
  newClientUnix,
  withClient,
  newClient,

  -- ** Local connection
  withLocalClient,
  newLocalClient,

  withStandaloneClient,
  withStandaloneProxy,

  -- ** Reconnecting client
  ReconnectingClient(..),
  ClientState(..),
  ClientDisposed(..),
  newReconnectingClient,
  withReconnectingClient,
) where

import Control.Monad.Catch
import Network.Socket qualified as Socket
import Quasar
import Quasar.Network.Channel
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Network.Server
import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Observable.ObservableVar
import Quasar.Prelude


data Client a = Client {
  quasar :: Quasar,
  root :: FutureEx '[SomeException] a
}

instance Disposable (Client a) where
  getDisposer client = getDisposer client.quasar

withClientTCP :: (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => Socket.HostName -> Socket.ServiceName -> up -> (Client down -> m b) -> m b
withClientTCP host port up = bracket (newClientTCP host port up) dispose

newClientTCP :: (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => Socket.HostName -> Socket.ServiceName -> up -> m (Client down)
newClientTCP host port up = do
  connection <- connectTCP host port
  newClient connection up


withClientUnix :: (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => FilePath -> up -> (Client down -> m a) -> m a
withClientUnix socketPath up = bracket (newClientUnix socketPath up) dispose

newClientUnix :: (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => FilePath -> up -> m (Client down)
newClientUnix socketPath up = do
  connection <- connectUnix socketPath
  newClient connection up


withClient :: forall up down m a. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => Connection -> up -> (Client down -> m a) -> m a
withClient connection up = bracket (newClient connection up) dispose


newClient :: forall up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => Connection -> up -> m (Client down)
newClient connection up = do
  rawChannel <- newMultiplexer MultiplexerSideA connection
  -- TODO send `up` (use Request, see obsidian notes)
  let channel = castChannel @(ReverseChannelType (NetworkRootReferenceChannel (FutureEx '[SomeException] down))) rawChannel
  (handler, root) <- atomicallyC $ receiveRootReference @(FutureEx '[SomeException] down) channel
  atomicallyC $ setChannelHandler channel handler
  pure Client {
    root,
    quasar = rawChannel.quasar
  }


-- ** Reconnecting

data ReconnectingClient up down = ReconnectingClient {
  up :: up,
  disposer :: Disposer,
  state :: Observable NoLoad '[] (ClientState down),
  root :: Observable Load '[SomeException] down
}

instance Disposable (ReconnectingClient up down) where
  getDisposer client = client.disposer

instance ToObservableT Load '[SomeException] Identity down (ReconnectingClient up down) where
  toObservableT client = toObservableT client.root

data ClientState a
  = ClientStateConnecting
  | ClientStateConnected (FutureEx '[SomeException] a)
  | ClientStateReconnecting SomeException
  | ClientStateDisposed

data ClientDisposed = ClientDisposed
  deriving (Eq, Show)
instance Exception ClientDisposed

newReconnectingClient :: forall up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => IO Connection -> up -> m (ReconnectingClient up down)
newReconnectingClient newConnection up = do
  scope <- newResourceScopeIO
  var <- newObservableVarIO ClientStateConnecting
  localQuasar scope do
    task <- async do
      -- TODO catch / loop
      withResourceScope do
        connection <- liftIO newConnection
        rawChannel <- newMultiplexer MultiplexerSideA connection
        -- TODO send `up` (use Request, see obsidian notes)
        let channel = castChannel @(ReverseChannelType (NetworkRootReferenceChannel (FutureEx '[SomeException] down))) rawChannel
        atomicallyC do
          (handler, root) <- receiveRootReference @(FutureEx '[SomeException] down) channel
          liftSTMc $ setChannelHandler channel handler
          writeObservableVar var (ClientStateConnected root)
        sleepForever
        -- wait for exception...

    let
      state = toObservable var
      root = liftObservable state >>= \case
        ClientStateConnecting -> constObservable ObservableStateLoading
        ClientStateConnected future -> toObservable future
        ClientStateReconnecting ex -> throwC ex
        ClientStateDisposed -> throwC ClientDisposed

    pure ReconnectingClient {
      disposer = getDisposer scope,
      up,
      state,
      root
    }


withReconnectingClient :: forall up down m b. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => IO Connection -> up -> (ReconnectingClient up down -> m b) -> m b
withReconnectingClient newConnection up = bracket (newReconnectingClient newConnection up) dispose


-- ** Local clients

withLocalClient :: forall a up down m b. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => Server a up down -> up -> (Client down -> m b) -> m b
withLocalClient server up action =
  withResourceScope do
    client <- newLocalClient server up
    action client

newLocalClient :: forall c up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => Server c up down -> up -> m (Client down)
newLocalClient server up =
  liftQuasarIO do
    mask_ do
      (clientConnection, serverConnection) <- newConnectionPair
      connectToServer server serverConnection
      newClient clientConnection up


-- ** Test implementation

withStandaloneClient :: forall c up down m b. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m, MonadMask m) => ServerConfig c up down -> up -> (Client down -> m b) -> m b
withStandaloneClient config up runClientHook = do
  server <- newServer config []
  withLocalClient server up runClientHook

withStandaloneProxy :: forall a m b. (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => a -> (a -> m b) -> m b
withStandaloneProxy obj fn = do
  bracket newChannelPair release \(x, y) -> do
    handlerX <- atomicallyC $ provideRootReference obj x
    atomicallyC $ setChannelHandler x handlerX
    (handlerY, proxy) <- atomicallyC $ receiveRootReference y
    atomicallyC $ setChannelHandler y handlerY
    fn proxy
  where
    release :: (NetworkRootReferenceChannel a, ReverseChannelType (NetworkRootReferenceChannel a)) -> m ()
    release (x, y) = dispose (getDisposer x <> getDisposer y)
