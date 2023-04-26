module Quasar.Network.Server (
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

data Server a = Server {
  quasar :: Quasar,
  root :: a
}

instance Disposable (Server a) where
  getDisposer server = getDisposer server.quasar


newServer :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => a -> [Listener] -> m (Server a)
newServer root listeners = do
  quasar <- newResourceScopeIO
  let server = Server { quasar, root }
  mapM_ (addListener_ server) listeners
  pure server

addListener :: (NetworkRootReference a, MonadIO m) => Server a -> Listener -> m Disposer
addListener server listener = runQuasarIO server.quasar $ getDisposer <$> async (runListener listener)
  where
    runListener :: Listener -> QuasarIO a
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

addListener_ :: (NetworkRootReference a, MonadIO m) => Server a -> Listener -> m ()
addListener_ server listener = void $ addListener server listener

runServer :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => a -> [Listener] -> m ()
runServer _ [] = liftIO $ throwM $ userError "Tried to start a server without any listeners"
runServer root listener = do
  server <- newServer root listener
  liftIO $ await $ isDisposed server

listenTCP :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => a -> Maybe Socket.HostName -> Socket.ServiceName -> m ()
listenTCP root mhost port = runServer root [TcpPort mhost port]

runTCPListener :: forall a m b. (NetworkRootReference a, MonadIO m, MonadMask m) => Server a -> Maybe Socket.HostName -> Socket.ServiceName -> m b
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

listenUnix :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => a -> FilePath -> m ()
listenUnix impl path = runServer @a impl [UnixSocket path]

runUnixSocketListener :: forall a m b. (NetworkRootReference a, MonadIO m, MonadMask m) => Server a -> FilePath -> m b
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
listenOnBoundSocket :: forall a m. (NetworkRootReference a, MonadQuasar m, MonadIO m) => a -> Socket.Socket -> m ()
listenOnBoundSocket protocolImpl socket = runServer @a protocolImpl [ListenSocket socket]

runListenerOnBoundSocket :: forall a m b. (NetworkRootReference a, MonadIO m, MonadMask m) => Server a -> Socket.Socket -> m b
runListenerOnBoundSocket server sock = do
  liftIO $ Socket.listen sock 1024
  forever $ mask_ $ do
    connection <- liftIO $ sockAddrConnection <$> Socket.accept sock
    connectToServer server connection

-- | Attach an established connection to a server.
connectToServer :: forall a m. (NetworkRootReference a, MonadIO m) => Server a -> Connection -> m ()
connectToServer server connection =
  -- Attach to server resource manager: When the server is closed, all listeners should be closed.
  runQuasarIO server.quasar do
    catchQuasar (queueLogError . formatException) do
      async_  do
        --logInfo $ mconcat ["Client connected (", connection.description, ")"]
        runMultiplexer MultiplexerSideB registerChannelServerHandler $ connection
        --logInfo $ mconcat ["Client connection closed (", connection.description, ")"]
  where
    registerChannelServerHandler :: RawChannel -> QuasarIO ()
    registerChannelServerHandler rawChannel = atomicallyC do
      let channel = castChannel rawChannel
      handler <- provideRootReference server.root channel
      setChannelHandler channel handler

    formatException :: SomeException -> String
    formatException (fromException -> Just (ConnectionLost (ReceiveFailed (fromException -> Just EOF)))) =
      mconcat ["Client connection lost (", connection.description, ")"]
    formatException (fromException -> Just (ConnectionLost ex)) =
      mconcat ["Client connection lost (", connection.description, "): ", displayException ex]
    formatException ex =
      mconcat ["Client exception (", connection.description, "): ", displayException ex]
