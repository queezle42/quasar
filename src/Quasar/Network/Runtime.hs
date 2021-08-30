module Quasar.Network.Runtime (
  -- * Client
  Client,
  clientClose,

  withClientTCP,
  newClientTCP,
  withClientUnix,
  newClientUnix,
  withClient,
  newClient,

  -- * Server
  Server,
  Listener(..),
  runServer,
  withServer,
  withLocalClient,
  newLocalClient,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,

  -- * Stream
  Stream,
  streamSend,
  streamSetHandler,
  streamClose,

  -- * Test implementation
  withStandaloneClient,

  -- * Internal runtime interface
  RpcProtocol(..),
  HasProtocolImpl(..),
  clientSend,
  clientRequest,
  clientReportProtocolError,
  newStream,
) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.Async (cancel, link, withAsync, mapConcurrently_)
import Control.Exception (bracket, bracketOnError, bracketOnError, interruptible, mask_)
import Control.Concurrent.MVar
import Data.Binary (Binary, encode, decodeOrFail)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import qualified Network.Socket as Socket
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)


class (Binary (ProtocolRequest p), Binary (ProtocolResponse p)) => RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p

type ProtocolResponseWrapper p = (MessageId, ProtocolResponse p)

class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleRequest :: MonadAsync m => ProtocolImpl p -> Channel -> ProtocolRequest p -> [Channel] -> m (Maybe (Task (ProtocolResponse p)))


data Client p = Client {
  channel :: Channel,
  stateMVar :: MVar (ClientState p)
}
newtype ClientState p = ClientState {
  callbacks :: HM.HashMap MessageId (ProtocolResponse p -> IO ())
}
emptyClientState :: ClientState p
emptyClientState = ClientState {
  callbacks = HM.empty
}

clientSend :: forall p m. (MonadIO m, RpcProtocol p) => Client p -> MessageConfiguration -> ProtocolRequest p -> m SentMessageResources
clientSend client config req = liftIO $ channelSend_ client.channel config (encode req)

clientRequest :: forall p m a. (MonadIO m, RpcProtocol p) => Client p -> (ProtocolResponse p -> Maybe a) -> MessageConfiguration -> ProtocolRequest p -> m (Awaitable a, SentMessageResources)
clientRequest client checkResponse config req = do
  resultAsync <- newAsyncVar
  sentMessageResources <- liftIO $ channelSend client.channel config (encode req) $ \msgId ->
    modifyMVar_ client.stateMVar $
      \state -> pure state{callbacks = HM.insert msgId (requestCompletedCallback resultAsync msgId) state.callbacks}
  pure (toAwaitable resultAsync, sentMessageResources)
  where
    requestCompletedCallback :: AsyncVar a -> MessageId -> ProtocolResponse p -> IO ()
    requestCompletedCallback resultAsync msgId response = do
      -- Remove callback
      modifyMVar_ client.stateMVar $ \state -> pure state{callbacks = HM.delete msgId state.callbacks}

      case checkResponse response of
        Nothing -> clientReportProtocolError client "Invalid response"
        Just result -> putAsyncVar_ resultAsync result

clientHandleChannelMessage :: forall p. (RpcProtocol p) => Client p -> ReceivedMessageResources -> BSL.ByteString -> IO ()
clientHandleChannelMessage client resources msg = case decodeOrFail msg of
  Left (_, _, errMsg) -> channelReportProtocolError client.channel errMsg
  Right ("", _, resp) -> clientHandleResponse resp
  Right (leftovers, _, _) -> channelReportProtocolError client.channel ("Response parser returned unexpected leftovers: " <> show (BSL.length leftovers))
  where
    clientHandleResponse :: ProtocolResponseWrapper p -> IO ()
    clientHandleResponse (requestId, resp) = do
      unless (null resources.createdChannels) (channelReportProtocolError client.channel "Received unexpected new channel during a rpc response")
      callback <- modifyMVar client.stateMVar $ \state -> do
        let (callbacks, mCallback) = lookupDelete requestId state.callbacks
        case mCallback of
          Just callback -> pure (state{callbacks}, callback)
          Nothing -> channelReportProtocolError client.channel ("Received response with invalid request id " <> show requestId)
      callback resp

clientClose :: Client p -> IO ()
clientClose client = channelClose client.channel

clientReportProtocolError :: Client p -> String -> IO a
clientReportProtocolError client = channelReportProtocolError client.channel


serverHandleChannelMessage :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Channel -> ReceivedMessageResources -> BSL.ByteString -> IO ()
serverHandleChannelMessage protocolImpl channel resources msg = case decodeOrFail msg of
    Left (_, _, errMsg) -> channelReportProtocolError channel errMsg
    Right ("", _, req) -> serverHandleChannelRequest resources.createdChannels req
    Right (leftovers, _, _) -> channelReportProtocolError channel ("Request parser pureed unexpected leftovers: " <> show (BSL.length leftovers))
  where
    serverHandleChannelRequest :: [Channel] -> ProtocolRequest p -> IO ()
    serverHandleChannelRequest channels req = do
      onResourceManager channel $
        handleRequest @p protocolImpl channel req channels >>= \case
          Nothing -> pure ()
          Just task -> do
            response <- await task
            liftIO $ serverSendResponse response
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = channelSendSimple channel (encode wrappedResponse)
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (resources.messageId, response)


newtype Stream up down = Stream Channel

newStream :: MonadIO m => Channel -> m (Stream up down)
newStream = liftIO . pure . Stream

streamSend :: (Binary up, MonadIO m) => Stream up down -> up -> m ()
streamSend (Stream channel) value = liftIO $ channelSendSimple channel (encode value)

streamSetHandler :: (Binary down, MonadIO m) => Stream up down -> (down -> IO ()) -> m ()
streamSetHandler (Stream channel) handler = liftIO $ channelSetSimpleHandler channel handler

streamClose :: MonadIO m => Stream up down -> m ()
streamClose (Stream channel) = liftIO $ channelClose channel

-- ** Running client and server

withClientTCP :: RpcProtocol p => Socket.HostName -> Socket.ServiceName -> (Client p -> IO a) -> IO a
withClientTCP host port = withClientBracket (newClientTCP host port)

newClientTCP :: forall p. RpcProtocol p => Socket.HostName -> Socket.ServiceName -> IO (Client p)
newClientTCP host port = newClient =<< connectTCP host port


withClientUnix :: RpcProtocol p => FilePath -> (Client p -> IO a) -> IO a
withClientUnix socketPath = withClientBracket (newClientUnix socketPath)

newClientUnix :: RpcProtocol p => FilePath -> IO (Client p)
newClientUnix socketPath = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
  Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
  Socket.connect sock $ Socket.SockAddrUnix socketPath
  newClient sock


withClient :: forall p a b. (IsConnection a, RpcProtocol p) => a -> (Client p -> IO b) -> IO b
withClient connection = withClientBracket (newClient connection)

newClient :: forall p a. (IsConnection a, RpcProtocol p) => a -> IO (Client p)
newClient connection = newChannelClient =<< newMultiplexer MultiplexerSideA (toSocketConnection connection)

withClientBracket :: forall p a. (RpcProtocol p) => IO (Client p) -> (Client p -> IO a) -> IO a
withClientBracket createClient = bracket createClient clientClose


newChannelClient :: RpcProtocol p => Channel -> IO (Client p)
newChannelClient channel = do
  stateMVar <- newMVar emptyClientState
  let client = Client {
    channel,
    stateMVar
  }
  channelSetHandler channel (clientHandleChannelMessage client)
  pure client

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

data Server p = Server {
  protocolImpl :: ProtocolImpl p
}

newServer :: forall p. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> IO (Server p)
newServer protocolImpl = pure Server { protocolImpl }

execServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> [Listener] -> IO a
execServer server listeners = mapConcurrently_ runListener listeners >> fail "Server failed: All listeners stopped unexpectedly"
  where
    runListener :: Listener -> IO ()
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

runServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> [Listener] -> IO a
runServer _ [] = fail "Tried to start a server without any listeners attached"
runServer protocolImpl listener = do
  server <- newServer @p protocolImpl
  execServer server listener

withServer :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> [Listener] -> (Server p -> IO a) -> IO a
withServer protocolImpl [] action = action =<< newServer @p protocolImpl
withServer protocolImpl listeners action = do
  server <- newServer @p protocolImpl
  withAsync (execServer server listeners) (\x -> link x >> action server <* cancel x)

listenTCP :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> IO a
listenTCP impl mhost port = runServer @p impl [TcpPort mhost port]

runTCPListener :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> Maybe Socket.HostName -> Socket.ServiceName -> IO a
runTCPListener server mhost port = do
  addr <- resolve
  bracket (open addr) Socket.close (runListenerOnBoundSocket server)
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

listenUnix :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> FilePath -> IO a
listenUnix impl path = runServer @p impl [UnixSocket path]

runUnixSocketListener :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> FilePath -> IO a
runUnixSocketListener server socketPath = do
  bracket create Socket.close (runListenerOnBoundSocket server)
  where
    create :: IO Socket.Socket
    create = do
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
listenOnBoundSocket :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> Socket.Socket -> IO a
listenOnBoundSocket protocolImpl socket = runServer @p protocolImpl [ListenSocket socket]

runListenerOnBoundSocket :: forall p a. (RpcProtocol p, HasProtocolImpl p) => Server p -> Socket.Socket -> IO a
runListenerOnBoundSocket server sock = do
  Socket.listen sock 1024
  forever $ mask_ $ do
    (conn, _sockAddr) <- Socket.accept sock
    connectToServer server conn

connectToServer :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsConnection a) => Server p -> a -> IO ()
connectToServer server conn = void $ forkFinally (interruptible (runServerHandler @p server.protocolImpl connection)) socketFinalization
  where
    connection :: Connection
    connection = toSocketConnection conn
    socketFinalization :: Either SomeException () -> IO ()
    socketFinalization (Left _err) = do
      -- TODO: log error
      --logStderr $ "Client connection closed with error " <> show err
      connection.close
    socketFinalization (Right ()) = do
      connection.close

runServerHandler :: forall p a. (RpcProtocol p, HasProtocolImpl p, IsConnection a) => ProtocolImpl p -> a -> IO ()
runServerHandler protocolImpl = runMultiplexer MultiplexerSideB registerChannelServerHandler . toSocketConnection
  where
    registerChannelServerHandler :: Channel -> IO ()
    registerChannelServerHandler channel = channelSetHandler channel (serverHandleChannelMessage @p protocolImpl channel)


withLocalClient :: forall p m a. (RpcProtocol p, HasProtocolImpl p) => Server p -> (Client p -> IO a) -> IO a
withLocalClient server = bracket (newLocalClient server) clientClose

newLocalClient :: forall p. (RpcProtocol p, HasProtocolImpl p) => Server p -> IO (Client p)
newLocalClient server = do
  unless Socket.isUnixDomainSocketAvailable $ fail "Unix domain sockets are not available"
  mask_ $ do
    (clientSocket, serverSocket) <- Socket.socketPair Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    connectToServer server serverSocket
    newClient @p clientSocket

-- ** Test implementation

withStandaloneClient :: forall p a. (RpcProtocol p, HasProtocolImpl p) => ProtocolImpl p -> (Client p -> IO a) -> IO a
withStandaloneClient impl runClientHook = withServer impl [] $ \server -> withLocalClient server runClientHook
