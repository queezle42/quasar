{-# LANGUAGE UndecidableSuperClasses #-}

module Quasar.Network.Runtime (
  -- * Client
  Client,

  withClientTCP,
  newClientTCP,
  withClientUnix,
  newClientUnix,
  withClient,
  newClient,

  -- * Server
  Server,
  Listener(..),
  newServer,
  runServer,
  addListener,
  addListener_,
  withLocalClient,
  newLocalClient,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,

  -- * Channel
  Channel,
  channelSend,
  channelSendDeferred,
  channelSetHandler,
  channelQuasar,
  unsafeQueueChannelMessage,

  -- * Test implementation
  withStandaloneClient,

  -- * Interacting with objects over network
  NetworkObject(..),
  NetworkReference(..),
  IsNetworkStrategy(..),
  IsChannel(..),

  -- * Internal runtime interface
  RpcProtocol(..),
  HasProtocolImpl(..),
  clientSend,
  clientRequest,
  clientReportProtocolError,
  newChannel,
) where

import Control.Monad.Catch
import Data.Binary (Binary(get, put), Get, Put, encode)
import Data.HashMap.Strict qualified as HM
import Network.Socket qualified as Socket
import Quasar
import Quasar.Async.Fork
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)

-- * Interacting with objects over network


class (IsChannel (ReverseChannelType a), a ~ ReverseChannelType (ReverseChannelType a)) => IsChannel a where
  type ReverseChannelType a
  castChannel :: RawChannel -> a

instance IsChannel RawChannel where
  type ReverseChannelType RawChannel = RawChannel
  castChannel :: RawChannel -> RawChannel
  castChannel = id

instance IsChannel (Channel up down) where
  type ReverseChannelType (Channel up down) = (Channel down up)
  castChannel :: RawChannel -> Channel up down
  castChannel = Channel


-- | Describes how a typeclass is used to send- and receive `NetworkObject`s.
type IsNetworkStrategy :: (Type -> Constraint) -> Constraint
class IsNetworkStrategy s where
  type ChannelIsRequired s :: Bool
  sendObject :: forall a. (NetworkObject a, NetworkStrategy a ~ s) => a -> Either Put (RawChannel -> QuasarIO ())
  receiveObject :: forall a. (NetworkObject a, NetworkStrategy a ~ s) => Either (Get a) (Future RawChannel -> QuasarIO a)

instance IsNetworkStrategy Binary where
  -- Copy by value by using `Binary`
  type ChannelIsRequired Binary = 'False
  sendObject x = Left (put x)
  receiveObject = Left get

instance IsNetworkStrategy NetworkReference where
  -- Send an object by reference with the `NetworkReference` class
  type ChannelIsRequired NetworkReference = 'True

  sendObject :: forall a. (NetworkObject a, NetworkStrategy a ~ NetworkReference) => a -> Either Put (RawChannel -> QuasarIO ())
  sendObject x = Right (\channel -> sendReference x (castChannel channel))

  receiveObject :: forall a. (NetworkObject a, NetworkStrategy a ~ NetworkReference) => Either (Get a) (Future RawChannel -> QuasarIO a)
  receiveObject = Right (\channel -> receiveReference (castChannel <$> channel))

class (IsNetworkStrategy (NetworkStrategy a), (NetworkStrategy a) a) => NetworkObject a where
  type NetworkStrategy a :: (Type -> Constraint)


class IsChannel (NetworkReferenceChannel a) => NetworkReference a where
  type NetworkReferenceChannel a
  sendReference :: a -> (NetworkReferenceChannel a -> QuasarIO ())
  receiveReference :: (Future (ReverseChannelType (NetworkReferenceChannel a)) -> QuasarIO a)


instance NetworkObject Bool where
  type NetworkStrategy Bool = Binary

instance NetworkObject Int where
  type NetworkStrategy Int = Binary

instance NetworkObject Float where
  type NetworkStrategy Float = Binary

instance NetworkObject Double where
  type NetworkStrategy Double = Binary

instance NetworkObject String where
  type NetworkStrategy String = Binary



-- * Old internal RPC types

class (Binary (ProtocolRequest p), Binary (ProtocolResponse p)) => RpcProtocol p where
  -- "Up"
  type ProtocolRequest p
  -- "Down"
  type ProtocolResponse p

type ProtocolResponseWrapper p = (MessageId, ProtocolResponse p)

class RpcProtocol p => HasProtocolImpl p where
  type ProtocolImpl p
  handleRequest :: ProtocolImpl p -> RawChannel -> ProtocolRequest p -> [RawChannel] -> QuasarIO (Maybe (Future (ProtocolResponse p)))


data Client p = Client {
  channel :: RawChannel,
  callbacksVar :: TVar (HM.HashMap MessageId (ProtocolResponse p -> IO ()))
}

instance Resource (Client p) where
  toDisposer client = toDisposer client.channel

clientSend :: forall p m. (MonadIO m, RpcProtocol p) => Client p -> MessageConfiguration -> ProtocolRequest p -> m SentMessageResources
clientSend client config req = liftIO $ sendRawChannelMessage client.channel config (encode req)

clientRequest :: forall p m a. (MonadIO m, RpcProtocol p) => Client p -> (ProtocolResponse p -> Maybe a) -> MessageConfiguration -> ProtocolRequest p -> m (Future a, SentMessageResources)
clientRequest client checkResponse config req = do
  resultPromise <- newPromise
  sentMessageResources <- liftIO $ sendRawChannelMessageDeferred client.channel config \msgId -> do
    modifyTVar client.callbacksVar $ HM.insert msgId (requestCompletedCallback resultPromise msgId)
    pure $ encode req
  pure (toFuture resultPromise, sentMessageResources)
  where
    requestCompletedCallback :: Promise a -> MessageId -> ProtocolResponse p -> IO ()
    requestCompletedCallback resultPromise msgId response = do
      -- Remove callback
      atomically $ modifyTVar client.callbacksVar $ HM.delete msgId

      case checkResponse response of
        Nothing -> clientReportProtocolError client "Invalid response"
        Just result -> fulfillPromise resultPromise result

-- TODO use new direct decoder api instead
clientHandleChannelMessage :: Client p -> ReceivedMessageResources -> ProtocolResponseWrapper p -> QuasarIO ()
clientHandleChannelMessage client resources (requestId, resp) = liftIO clientHandleResponse
  where
    clientHandleResponse :: IO ()
    clientHandleResponse = do
      unless (null resources.createdChannels) (channelReportProtocolError client.channel "Received unexpected new channel during a rpc response")
      join $ atomically $ stateTVar client.callbacksVar $ \oldCallbacks -> do
        let (mCallback, callbacks) = lookupDelete requestId oldCallbacks
        case mCallback of
          Just callback -> (callback resp, callbacks)
          Nothing -> (channelReportProtocolError client.channel ("Received response with invalid request id " <> show requestId), callbacks)

clientReportProtocolError :: Client p -> String -> IO a
clientReportProtocolError client = channelReportProtocolError client.channel


serverHandleChannelMessage :: forall p. (HasProtocolImpl p) => ProtocolImpl p -> RawChannel -> ReceivedMessageResources -> ProtocolRequest p -> QuasarIO ()
serverHandleChannelMessage protocolImpl channel resources req = liftIO $ serverHandleChannelRequest resources.createdChannels req
  where
    serverHandleChannelRequest :: [RawChannel] -> ProtocolRequest p -> IO ()
    serverHandleChannelRequest channels req = do
      runQuasarIO channel.quasar do
        handleRequest @p protocolImpl channel req channels >>= \case
          Nothing -> pure ()
          Just task -> do
            response <- await task
            liftIO $ serverSendResponse response
    serverSendResponse :: ProtocolResponse p -> IO ()
    serverSendResponse response = sendSimpleRawChannelMessage channel (encode wrappedResponse)
      where
        wrappedResponse :: ProtocolResponseWrapper p
        wrappedResponse = (resources.messageId, response)


newtype Channel up down = Channel RawChannel
  deriving newtype Resource

newChannel :: MonadIO m => RawChannel -> m (Channel up down)
newChannel = liftIO . pure . Channel

channelSend :: (Binary up, MonadIO m) => Channel up down -> up -> m ()
channelSend (Channel channel) value = liftIO $ sendSimpleRawChannelMessage channel (encode value)

channelSendDeferred :: (Binary up, MonadIO m) => Channel up down -> STM up -> m ()
channelSendDeferred (Channel channel) value = liftIO $ sendSimpleRawChannelMessageDeferred channel (const (encode <$> value))

unsafeQueueChannelMessage :: (Binary up, MonadSTM m) => Channel up down -> up -> m ()
unsafeQueueChannelMessage (Channel channel) value = liftSTM do
  unsafeQueueRawChannelMessageSimple channel (encode value)

channelSetHandler :: (Binary down, MonadIO m) => Channel up down -> (down -> QuasarIO ()) -> m ()
channelSetHandler (Channel channel) handler = liftIO $ rawChannelSetSimpleBinaryHandler channel handler

channelQuasar :: Channel up down -> Quasar
channelQuasar (Channel s) = s.quasar

-- ** Running client and server

withClientTCP :: (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => Socket.HostName -> Socket.ServiceName -> (Client p -> m a) -> m a
withClientTCP host port = withClientBracket (newClientTCP host port)

newClientTCP :: (RpcProtocol p, MonadQuasar m, MonadIO m) => Socket.HostName -> Socket.ServiceName -> m (Client p)
newClientTCP host port = newClient =<< connectTCP host port


withClientUnix :: (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => FilePath -> (Client p -> m a) -> m a
withClientUnix socketPath = withClientBracket (newClientUnix socketPath)

newClientUnix :: (RpcProtocol p, MonadQuasar m, MonadIO m) => FilePath -> m (Client p)
newClientUnix socketPath = liftQuasarIO do
  bracketOnError
    do liftIO $ Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
    do liftIO . Socket.close
    \sock -> do
      liftIO do
        Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
        Socket.connect sock $ Socket.SockAddrUnix socketPath
      newClient $ socketConnection socketPath sock


withClient :: forall p m a. (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => Connection -> (Client p -> m a) -> m a
withClient connection = withClientBracket (newClient connection)

newClient :: forall p m. (RpcProtocol p, MonadQuasar m, MonadIO m) => Connection -> m (Client p)
newClient connection = liftIO . newChannelClient =<< newMultiplexer MultiplexerSideA connection

withClientBracket :: (MonadIO m, MonadMask m) => m (Client p) -> (Client p -> m a) -> m a
-- No resource scope has to becreated here because a client already is a new scope
withClientBracket createClient = bracket createClient (liftIO . dispose)


newChannelClient :: RpcProtocol p => RawChannel -> IO (Client p)
newChannelClient channel = do
  callbacksVar <- liftIO $ newTVarIO mempty
  let client = Client {
    channel,
    callbacksVar
  }
  rawChannelSetBinaryHandler channel (clientHandleChannelMessage client)
  pure client

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

data Server p = Server {
  quasar :: Quasar,
  protocolImpl :: ProtocolImpl p
}

instance Resource (Server p) where
  toDisposer server = toDisposer server.quasar


newServer :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> [Listener] -> m (Server p)
newServer protocolImpl listeners = do
  quasar <- newResourceScopeIO
  let server = Server { quasar, protocolImpl }
  mapM_ (addListener_ server) listeners
  pure server

addListener :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m Disposer
addListener server listener = runQuasarIO server.quasar $ toDisposer <$> async (runListener listener)
  where
    runListener :: Listener -> QuasarIO a
    runListener (TcpPort mhost port) = runTCPListener server mhost port
    runListener (UnixSocket path) = runUnixSocketListener server path
    runListener (ListenSocket socket) = runListenerOnBoundSocket server socket

addListener_ :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m ()
addListener_ server listener = void $ addListener server listener

runServer :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> [Listener] -> m ()
runServer _ [] = liftIO $ throwM $ userError "Tried to start a server without any listeners"
runServer protocolImpl listener = do
  server <- newServer @p protocolImpl listener
  liftIO $ await $ isDisposed server

listenTCP :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> m ()
listenTCP impl mhost port = runServer @p impl [TcpPort mhost port]

runTCPListener :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> Maybe Socket.HostName -> Socket.ServiceName -> m a
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

listenUnix :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> FilePath -> m ()
listenUnix impl path = runServer @p impl [UnixSocket path]

runUnixSocketListener :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> FilePath -> m a
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
listenOnBoundSocket :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> Socket.Socket -> m ()
listenOnBoundSocket protocolImpl socket = runServer @p protocolImpl [ListenSocket socket]

runListenerOnBoundSocket :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> Socket.Socket -> m a
runListenerOnBoundSocket server sock = do
  liftIO $ Socket.listen sock 1024
  forever $ mask_ $ do
    connection <- liftIO $ sockAddrConnection <$> Socket.accept sock
    connectToServer server connection

connectToServer :: forall p m. (HasProtocolImpl p, MonadIO m) => Server p -> Connection -> m ()
connectToServer server connection =
  -- Attach to server resource manager: When the server is closed, all listeners should be closed.
  runQuasarIO server.quasar do
    connectionMessages <- liftIO newTQueueIO

    afix_ \(join -> done) -> do

      -- TODO use quasar logger
      quasar <- askQuasar
      liftIO $ fork_ (runQuasarIO quasar (logUntilDone done connectionMessages)) (quasarExceptionSink quasar)

      catchQuasar (writeTQueue connectionMessages . formatException) do
        async_  do
          --logInfo $ mconcat ["Client connected (", connection.description, ")"]

          runMultiplexer MultiplexerSideB registerChannelServerHandler $ connection

          --logInfo $ mconcat ["Client connection closed (", connection.description, ")"]

        -- Capture inner quasar - used to terminate connection logger once everything is closed.
        isDisposed <$> askQuasar
  where
    registerChannelServerHandler :: RawChannel -> QuasarIO ()
    registerChannelServerHandler channel = liftIO do
      rawChannelSetBinaryHandler channel (serverHandleChannelMessage @p server.protocolImpl channel)

    formatException :: SomeException -> String
    formatException (fromException -> Just (ConnectionLost (ReceiveFailed (fromException -> Just EOF)))) =
      mconcat ["Client connection lost (", connection.description, ")"]
    formatException (fromException -> Just (ConnectionLost ex)) =
      mconcat ["Client connection lost (", connection.description, "): ", displayException ex]
    formatException ex =
      mconcat ["Client exception (", connection.description, "): ", displayException ex]

    logUntilDone :: Future () -> TQueue String -> QuasarIO ()
    logUntilDone done messageQueue =
      join $ atomically $
        ((\msg -> logError msg >> logUntilDone done messageQueue) <$> readTQueue messageQueue)
          `orElse`
            (pure () <$ peekFutureSTM done)


withLocalClient :: forall p a m. (HasProtocolImpl p, MonadQuasar m, MonadIO m, MonadMask m) => Server p -> (Client p -> m a) -> m a
withLocalClient server action =
  withResourceScope do
    client <- newLocalClient server
    action client

newLocalClient :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => Server p -> m (Client p)
newLocalClient server =
  liftQuasarIO do
    mask_ do
      (clientSocket, serverSocket) <- newConnectionPair
      connectToServer server serverSocket
      newClient @p clientSocket

-- ** Test implementation

withStandaloneClient :: forall p a m. (HasProtocolImpl p, MonadQuasar m, MonadIO m, MonadMask m) => ProtocolImpl p -> (Client p -> m a) -> m a
withStandaloneClient impl runClientHook = do
  server <- newServer impl []
  withLocalClient server runClientHook
