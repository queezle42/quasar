module Quasar.Network.Server (
  -- * Server configuration
  ServerConfig(..),
  simpleServerConfig,

  -- * Server
  Server,
  Listener(..),
  newServer,
  runServer,
  addListener,
  addListener_,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,
  connectToServer,
) where

import Control.Monad.Catch
import Network.Socket qualified as Socket
import Quasar
import Quasar.Observable.Core (NoLoad)
import Quasar.Observable.List (ObservableList)
import Quasar.Observable.List qualified as ObservableList
import Quasar.Network.Channel
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime
import Quasar.Prelude
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

data ServerConfig client up down = ServerConfig {
  root :: down,
  onOpen :: ServerConnection -> up -> IO (client, down),
  onClose :: client -> IO ()
}

data ServerConnection = ServerConnection

simpleServerConfig :: down -> ServerConfig () () down
simpleServerConfig root = ServerConfig {
  root,
  onOpen = \_ () -> pure ((), root),
  onClose = \_ -> pure ()
}

data Server client up down = Server {
  quasar :: Quasar,
  config :: ServerConfig client up down
  --clients :: ObservableListVar NoLoad client
}

instance Disposable (Server client up down) where
  getDisposer server = getDisposer server.quasar


newServer ::
  forall client up down m.
  (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) =>
  ServerConfig client up down ->
  [Listener] ->
  m (Server client up down)
newServer config listeners = do
  quasar <- newResourceScopeIO
  --clients <- undefined
  let server = Server { quasar, config }
  mapM_ (addListener_ server) listeners
  pure server

addListener :: (NetworkObject up, NetworkObject down, MonadIO m) => Server client up down -> Listener -> m Disposer
addListener server listener = runQuasarIO server.quasar $ getDisposer <$> async (runListener listener)
  where
    runListener :: Listener -> QuasarIO a
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

addListener_ :: (NetworkObject up, NetworkObject down, MonadIO m) => Server client up down -> Listener -> m ()
addListener_ server listener = void $ addListener server listener

runServer :: forall client up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => ServerConfig client up down -> [Listener] -> m ()
runServer _ [] = liftIO $ throwM $ userError "Tried to start a server without any listeners"
runServer root listener = do
  server <- newServer root listener
  liftIO $ await $ isDisposed server

listenTCP :: forall client up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => ServerConfig client up down -> Maybe Socket.HostName -> Socket.ServiceName -> m ()
listenTCP root mhost port = runServer root [TcpPort mhost port]

runTCPListener :: forall client up down m b. (NetworkObject up, NetworkObject down, MonadIO m, MonadMask m) => Server client up down -> Maybe Socket.HostName -> Socket.ServiceName -> m b
runTCPListener server mhost port = do
  addr <- liftIO resolve
  bracket (liftIO (open addr)) (liftIO . Socket.close) (runListenerOnBoundSocket server)
  where
    resolve :: IO Socket.AddrInfo
    resolve = do
      let hints = Socket.defaultHints {Socket.addrFlags=[Socket.AI_PASSIVE], Socket.addrSocketType=Socket.Stream}
      (addr:_) <- Socket.getAddrInfo (Just hints) mhost (Just port)
      pure addr
    open :: Socket.AddrInfo -> IO Socket.Socket
    open addr = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.bind sock (Socket.addrAddress addr)
      pure sock

listenUnix :: forall client up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => ServerConfig client up down -> FilePath -> m ()
listenUnix config path = runServer config [UnixSocket path]

runUnixSocketListener :: forall client up down m b. (NetworkObject up, NetworkObject down, MonadIO m, MonadMask m) => Server client up down -> FilePath -> m b
runUnixSocketListener server socketPath = do
  bracket create (liftIO . Socket.close) (runListenerOnBoundSocket server)
  where
    create :: m Socket.Socket
    create = liftIO do
      fileExistsAtPath <- fileExist socketPath
      when fileExistsAtPath $ do
        fileStatus <- getFileStatus socketPath
        if isSocket fileStatus
          then removeLink socketPath
          else fail "Cannot bind socket: Socket path is not empty"

      bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.bind sock (Socket.SockAddrUnix socketPath)
        pure sock

-- | Listen and accept connections on an already bound socket.
listenOnBoundSocket :: forall client up down m. (NetworkObject up, NetworkObject down, MonadQuasar m, MonadIO m) => ServerConfig client up down -> Socket.Socket -> m ()
listenOnBoundSocket config socket = runServer config [ListenSocket socket]

runListenerOnBoundSocket :: forall client up down m b. (NetworkObject up, NetworkObject down, MonadIO m, MonadMask m) => Server client up down -> Socket.Socket -> m b
runListenerOnBoundSocket server sock = do
  liftIO $ Socket.listen sock 1024
  forever $ mask_ $ do
    connection <- liftIO $ sockAddrConnection <$> Socket.accept sock
    connectToServer server connection

-- | Attach an established connection to a server.
connectToServer :: forall client up down m. (NetworkObject up, NetworkObject down, MonadIO m) => Server client up down -> Connection -> m ()
connectToServer server connection =
  -- Attach to server resource manager: When the server is closed, all listeners should be closed.
  runQuasarIO server.quasar do
    catchQuasar (queueLogError . formatException) do
      async_  do
        --logInfo $ mconcat ["Client connected (", connection.description, ")"]
        runMultiplexer MultiplexerSideB registerChannelServerHandler connection
        --logInfo $ mconcat ["Client connection closed (", connection.description, ")"]
  where
    registerChannelServerHandler :: RawChannel -> QuasarIO ()
    registerChannelServerHandler rawChannel = atomicallyC do
      let channel = castChannel rawChannel
      -- TODO send `up` (use Request, see obsidian notes)
      handler <- provideRootReference @(FutureEx '[SomeException] down) (pure server.config.root) channel
      setChannelHandler channel handler

    formatException :: SomeException -> String
    formatException (fromException -> Just (ConnectionLost (ReceiveFailed (fromException -> Just EOF)))) =
      mconcat ["Client connection lost (", connection.description, ")"]
    formatException (fromException -> Just (ConnectionLost ex)) =
      mconcat ["Client connection lost (", connection.description, "): ", displayException ex]
    formatException ex =
      mconcat ["Client exception (", connection.description, "): ", displayException ex]
