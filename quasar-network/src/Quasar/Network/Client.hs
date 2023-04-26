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
) where

import Control.Monad.Catch
import Network.Socket qualified as Socket
import Quasar
import Quasar.Network.Channel
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Network.Server
import Quasar.Prelude


data Client a = Client {
  quasar :: Quasar,
  root :: a
}

instance Disposable (Client a) where
  getDisposer client = getDisposer client.quasar

withClientTCP :: (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => Socket.HostName -> Socket.ServiceName -> (Client a -> m b) -> m b
withClientTCP host port = bracket (newClientTCP host port) dispose

newClientTCP :: (NetworkRootReference a, MonadQuasar m, MonadIO m) => Socket.HostName -> Socket.ServiceName -> m (Client a)
newClientTCP host port = newClient =<< connectTCP host port


withClientUnix :: (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => FilePath -> (Client a -> m b) -> m b
withClientUnix socketPath = bracket (newClientUnix socketPath) dispose

newClientUnix :: (NetworkRootReference a, MonadQuasar m, MonadIO m) => FilePath -> m (Client a)
newClientUnix socketPath = newClient =<< connectUnix socketPath


withClient :: forall a m b. (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => Connection -> (Client a -> m b) -> m b
withClient connection = bracket (newClient connection) dispose


newClient :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => Connection -> m (Client a)
newClient connection = do
  rawChannel <- newMultiplexer MultiplexerSideA connection
  let channel = castChannel @(ReverseChannelType (NetworkRootReferenceChannel a)) rawChannel
  (handler, root) <- atomicallyC $ receiveRootReference @a channel
  atomicallyC $ setChannelHandler channel handler
  pure Client {
    root,
    quasar = rawChannel.quasar
  }

-- ** Local clients

withLocalClient :: forall a m b. (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => Server a -> (Client a -> m b) -> m b
withLocalClient server action =
  withResourceScope do
    client <- newLocalClient server
    action client

newLocalClient :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => Server a -> m (Client a)
newLocalClient server =
  liftQuasarIO do
    mask_ do
      (clientConnection, serverConnection) <- newConnectionPair
      connectToServer server serverConnection
      newClient @a clientConnection


-- ** Test implementation

withStandaloneClient :: forall a m b. (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => a -> (Client a -> m b) -> m b
withStandaloneClient impl runClientHook = do
  server <- newServer impl []
  withLocalClient server runClientHook

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
