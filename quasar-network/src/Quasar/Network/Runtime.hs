{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Quasar.Network.Runtime (
  -- * Client
  --Client,
  --withClientTCP,
  --newClientTCP,
  --withClientUnix,
  --newClientUnix,
  --withClient,
  --newClient,

  -- * Server
  --Server,
  --Listener(..),
  --newServer,
  --runServer,
  --addListener,
  --addListener_,
  --withLocalClient,
  --newLocalClient,
  --listenTCP,
  --listenUnix,
  --listenOnBoundSocket,

  -- * Channel
  Channel,
  channelSend,
  sendChannelMessageDeferred,
  sendSimpleChannelMessageDeferred,
  ChannelHandler,
  channelSetHandler,
  channelSetSimpleHandler,
  channelQuasar,
  unsafeQueueChannelMessage,
  newChannelPair,

  -- * Test implementation
  --withStandaloneClient,
  withStandaloneProxy,

  -- * Interacting with objects over network
  NetworkObject(..),
  NetworkReference(..),
  IsNetworkStrategy(..),
  IsChannel(..),
  CData,
) where

import Control.Monad.Catch
import Data.Bifunctor (first)
import Data.Binary (Binary, encode)
import Data.HashMap.Strict qualified as HM
import GHC.Records
import Network.Socket qualified as Socket
import Quasar
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import Quasar.Utils.HashMap qualified as HM
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)

-- * Interacting with objects over network


type IsChannel :: Type -> Constraint
class (IsChannel (ReverseChannelType a), a ~ ReverseChannelType (ReverseChannelType a), Disposable a) => IsChannel a where
  type ReverseChannelType a
  type ChannelHandlerType a
  castChannel :: RawChannel -> a
  rawChannelHandler :: ChannelHandlerType a -> RawChannelHandler
  setChannelHandler :: a -> ChannelHandlerType a -> STMc NoRetry '[] ()

instance IsChannel RawChannel where
  type ReverseChannelType RawChannel = RawChannel
  type ChannelHandlerType RawChannel = RawChannelHandler
  castChannel :: RawChannel -> RawChannel
  castChannel = id
  rawChannelHandler :: RawChannelHandler -> RawChannelHandler
  rawChannelHandler = id
  setChannelHandler = rawChannelSetHandler


instance (Binary up, Binary down) => IsChannel (Channel up down) where
  type ReverseChannelType (Channel up down) = (Channel down up)
  type ChannelHandlerType (Channel up down) = ChannelHandler down
  castChannel :: RawChannel -> Channel up down
  castChannel = Channel
  rawChannelHandler :: ChannelHandler down -> RawChannelHandler
  rawChannelHandler = binaryHandler
  setChannelHandler :: Channel up down -> ChannelHandler down -> STMc NoRetry '[] ()
  setChannelHandler (Channel channel) handler = rawChannelSetHandler channel (binaryHandler handler)

type ReverseChannelHandlerType a = ChannelHandlerType (ReverseChannelType a)


type ChannelHandler a = ReceivedMessageResources -> a -> QuasarIO ()


-- | Describes how a typeclass is used to send- and receive `NetworkObject`s.
type IsNetworkStrategy :: (Type -> Constraint) -> Type -> Constraint
class (s a, NetworkObject a, Binary (CData a)) => IsNetworkStrategy s a where
  type StrategyCData s a :: Type
  sendObject :: NetworkStrategy a ~ s => a -> (CData a, Maybe (RawChannel -> QuasarIO ()))
  receiveObject :: NetworkStrategy a ~ s => CData a -> Either a (RawChannel -> STMc NoRetry '[] (RawChannelHandler, a))


type CData :: Type -> Type
type CData a = StrategyCData (NetworkStrategy a) a

class (IsNetworkStrategy (NetworkStrategy a) a, Binary (CData a)) => NetworkObject a where
  type NetworkStrategy a :: (Type -> Constraint)


instance (Binary a, NetworkObject a) => IsNetworkStrategy Binary a where
  -- Copy by value by using `Binary`
  type StrategyCData Binary a = a
  sendObject x = (x, Nothing)
  receiveObject = Left

instance (NetworkReference a, NetworkObject a) => IsNetworkStrategy NetworkReference a where
  -- Send an object by reference with the `NetworkReference` class
  type StrategyCData NetworkReference _ = ()
  sendObject x = ((), Just \channel -> sendReference x (castChannel channel))
  receiveObject () = Right \channel -> first (rawChannelHandler @(ReverseChannelType (NetworkReferenceChannel a))) <$> receiveReference (castChannel channel)


class IsChannel (NetworkReferenceChannel a) => NetworkReference a where
  type NetworkReferenceChannel a
  sendReference :: a -> NetworkReferenceChannel a -> QuasarIO ()
  receiveReference :: ReverseChannelType (NetworkReferenceChannel a) -> STMc NoRetry '[] (ReverseChannelHandlerType (NetworkReferenceChannel a), a)


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



type Channel :: Type -> Type -> Type
newtype Channel up down = Channel RawChannel
  deriving newtype Disposable

instance HasField "quasar" (Channel up down) Quasar where
  getField (Channel rawChannel) = rawChannel.quasar

channelSend :: (Binary up, MonadIO m) => Channel up down -> up -> m ()
channelSend (Channel channel) value = liftIO $ sendSimpleRawChannelMessage channel (encode value)

sendChannelMessageDeferred :: (Binary up, MonadIO m) => Channel up down -> STMc NoRetry '[AbortSend] (ChannelMessage up, a) -> m (SentMessageResources, a)
sendChannelMessageDeferred (Channel channel) payloadHook = liftIO $ sendRawChannelMessageDeferred channel (const (first (fmap encode) <$> payloadHook))

sendSimpleChannelMessageDeferred :: (Binary up, MonadIO m) => Channel up down -> STMc NoRetry '[AbortSend] (up, a) -> m a
sendSimpleChannelMessageDeferred (Channel channel) payloadHook = liftIO $ sendSimpleRawChannelMessageDeferred channel (const (first encode <$> payloadHook))

unsafeQueueChannelMessage :: (Binary up, MonadSTMc NoRetry '[AbortSend, ChannelException, MultiplexerException] m) => Channel up down -> up -> m ()
unsafeQueueChannelMessage (Channel channel) value =
  unsafeQueueRawChannelMessageSimple channel (encode value)

channelSetHandler :: (Binary down, MonadSTMc NoRetry '[] m) => Channel up down -> ChannelHandler down -> m ()
channelSetHandler (Channel s) fn = rawChannelSetHandler s (binaryHandler fn)

channelSetSimpleHandler :: (Binary down, MonadSTMc NoRetry '[] m) => Channel up down -> (down -> QuasarIO ()) -> m ()
channelSetSimpleHandler (Channel channel) fn = rawChannelSetHandler channel (simpleBinaryHandler fn)

channelQuasar :: Channel up down -> Quasar
channelQuasar (Channel s) = s.quasar

-- ** Running client and server

-- withClientTCP :: (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => Socket.HostName -> Socket.ServiceName -> (Client p -> m a) -> m a
-- withClientTCP host port = withClientBracket (newClientTCP host port)
--
-- newClientTCP :: (RpcProtocol p, MonadQuasar m, MonadIO m) => Socket.HostName -> Socket.ServiceName -> m (Client p)
-- newClientTCP host port = newClient =<< connectTCP host port
--
--
-- withClientUnix :: (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => FilePath -> (Client p -> m a) -> m a
-- withClientUnix socketPath = withClientBracket (newClientUnix socketPath)
--
-- newClientUnix :: (RpcProtocol p, MonadQuasar m, MonadIO m) => FilePath -> m (Client p)
-- newClientUnix socketPath = liftQuasarIO do
--   bracketOnError
--     do liftIO $ Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
--     do liftIO . Socket.close
--     \sock -> do
--       liftIO do
--         Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
--         Socket.connect sock $ Socket.SockAddrUnix socketPath
--       newClient $ socketConnection socketPath sock
--
--
-- withClient :: forall p m a. (RpcProtocol p, MonadQuasar m, MonadIO m, MonadMask m) => Connection -> (Client p -> m a) -> m a
-- withClient connection = withClientBracket (newClient connection)
--
-- newClient :: forall p m. (RpcProtocol p, MonadQuasar m, MonadIO m) => Connection -> m (Client p)
-- newClient connection = liftIO . newChannelClient =<< newMultiplexer MultiplexerSideA connection
--
-- withClientBracket :: (MonadIO m, MonadMask m) => m (Client p) -> (Client p -> m a) -> m a
-- -- No resource scope has to becreated here because a client already is a new scope
-- withClientBracket createClient = bracket createClient (liftIO . dispose)
--
--
-- newChannelClient :: RpcProtocol p => RawChannel -> IO (Client p)
-- newChannelClient channel = do
--   callbacksVar <- liftIO $ newTVarIO mempty
--   let client = Client {
--     channel,
--     callbacksVar
--   }
--   rawChannelSetBinaryHandler channel (clientHandleChannelMessage client)
--   pure client

data Listener =
  TcpPort (Maybe Socket.HostName) Socket.ServiceName |
  UnixSocket FilePath |
  ListenSocket Socket.Socket

-- data Server p = Server {
--   quasar :: Quasar,
--   protocolImpl :: ProtocolImpl p
-- }
--
-- instance Disposable (Server p) where
--   getDisposer server = getDisposer server.quasar
--
--
-- newServer :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> [Listener] -> m (Server p)
-- newServer protocolImpl listeners = do
--   quasar <- newResourceScopeIO
--   let server = Server { quasar, protocolImpl }
--   mapM_ (addListener_ server) listeners
--   pure server
--
-- addListener :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m Disposer
-- addListener server listener = runQuasarIO server.quasar $ getDisposer <$> async (runListener listener)
--   where
--     runListener :: Listener -> QuasarIO a
--     runListener (TcpPort mhost port) = runTCPListener server mhost port
--     runListener (UnixSocket path) = runUnixSocketListener server path
--     runListener (ListenSocket socket) = runListenerOnBoundSocket server socket
--
-- addListener_ :: (HasProtocolImpl p, MonadIO m) => Server p -> Listener -> m ()
-- addListener_ server listener = void $ addListener server listener
--
-- runServer :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> [Listener] -> m ()
-- runServer _ [] = liftIO $ throwM $ userError "Tried to start a server without any listeners"
-- runServer protocolImpl listener = do
--   server <- newServer @p protocolImpl listener
--   liftIO $ await $ isDisposed server
--
-- listenTCP :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> Maybe Socket.HostName -> Socket.ServiceName -> m ()
-- listenTCP impl mhost port = runServer @p impl [TcpPort mhost port]
--
-- runTCPListener :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> Maybe Socket.HostName -> Socket.ServiceName -> m a
-- runTCPListener server mhost port = do
--   addr <- liftIO resolve
--   bracket (liftIO (open addr)) (liftIO . Socket.close) (runListenerOnBoundSocket server)
--   where
--     resolve :: IO Socket.AddrInfo
--     resolve = do
--       let hints = Socket.defaultHints {Socket.addrFlags=[Socket.AI_PASSIVE], Socket.addrSocketType=Socket.Stream}
--       (addr:_) <- Socket.getAddrInfo (Just hints) mhost (Just port)
--       pure addr
--     open :: Socket.AddrInfo -> IO Socket.Socket
--     open addr = bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
--       Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
--       Socket.bind sock (Socket.addrAddress addr)
--       pure sock
--
-- listenUnix :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> FilePath -> m ()
-- listenUnix impl path = runServer @p impl [UnixSocket path]
--
-- runUnixSocketListener :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> FilePath -> m a
-- runUnixSocketListener server socketPath = do
--   bracket create (liftIO . Socket.close) (runListenerOnBoundSocket server)
--   where
--     create :: m Socket.Socket
--     create = liftIO do
--       fileExistsAtPath <- fileExist socketPath
--       when fileExistsAtPath $ do
--         fileStatus <- getFileStatus socketPath
--         if isSocket fileStatus
--           then removeLink socketPath
--           else fail "Cannot bind socket: Socket path is not empty"
--
--       bracketOnError (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
--         Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
--         Socket.bind sock (Socket.SockAddrUnix socketPath)
--         pure sock
--
-- -- | Listen and accept connections on an already bound socket.
-- listenOnBoundSocket :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => ProtocolImpl p -> Socket.Socket -> m ()
-- listenOnBoundSocket protocolImpl socket = runServer @p protocolImpl [ListenSocket socket]
--
-- runListenerOnBoundSocket :: forall p a m. (HasProtocolImpl p, MonadIO m, MonadMask m) => Server p -> Socket.Socket -> m a
-- runListenerOnBoundSocket server sock = do
--   liftIO $ Socket.listen sock 1024
--   forever $ mask_ $ do
--     connection <- liftIO $ sockAddrConnection <$> Socket.accept sock
--     connectToServer server connection
--
-- connectToServer :: forall p m. (HasProtocolImpl p, MonadIO m) => Server p -> Connection -> m ()
-- connectToServer server connection =
--   -- Attach to server resource manager: When the server is closed, all listeners should be closed.
--   runQuasarIO server.quasar do
--     catchQuasar (queueLogError . formatException) do
--       async_  do
--         --logInfo $ mconcat ["Client connected (", connection.description, ")"]
--         runMultiplexer MultiplexerSideB registerChannelServerHandler $ connection
--         --logInfo $ mconcat ["Client connection closed (", connection.description, ")"]
--   where
--     registerChannelServerHandler :: RawChannel -> QuasarIO ()
--     registerChannelServerHandler channel = liftIO do
--       rawChannelSetBinaryHandler channel (serverHandleChannelMessage @p server.protocolImpl channel)
--
--     formatException :: SomeException -> String
--     formatException (fromException -> Just (ConnectionLost (ReceiveFailed (fromException -> Just EOF)))) =
--       mconcat ["Client connection lost (", connection.description, ")"]
--     formatException (fromException -> Just (ConnectionLost ex)) =
--       mconcat ["Client connection lost (", connection.description, "): ", displayException ex]
--     formatException ex =
--       mconcat ["Client exception (", connection.description, "): ", displayException ex]
--
--
-- withLocalClient :: forall p a m. (HasProtocolImpl p, MonadQuasar m, MonadIO m, MonadMask m) => Server p -> (Client p -> m a) -> m a
-- withLocalClient server action =
--   withResourceScope do
--     client <- newLocalClient server
--     action client
--
-- newLocalClient :: forall p m. (HasProtocolImpl p, MonadQuasar m, MonadIO m) => Server p -> m (Client p)
-- newLocalClient server =
--   liftQuasarIO do
--     mask_ do
--       (clientSocket, serverSocket) <- newConnectionPair
--       connectToServer server serverSocket
--       newClient @p clientSocket

newChannelPair :: (IsChannel a, MonadQuasar m, MonadIO m) => m (a, ReverseChannelType a)
newChannelPair = liftQuasarIO do
  (clientSocket, serverSocket) <- newConnectionPair
  clientChannel <- newMultiplexer MultiplexerSideA clientSocket
  serverChannel <- newMultiplexer MultiplexerSideB serverSocket
  pure (castChannel clientChannel, castChannel serverChannel)

-- ** Test implementation

-- withStandaloneClient :: forall p a m. (HasProtocolImpl p, MonadQuasar m, MonadIO m, MonadMask m) => ProtocolImpl p -> (Client p -> m a) -> m a
-- withStandaloneClient impl runClientHook = do
--   server <- newServer impl []
--   withLocalClient server runClientHook

withStandaloneProxy :: forall a m b. (NetworkReference a, MonadQuasar m, MonadIO m, MonadMask m) => a -> (a -> m b) -> m b
withStandaloneProxy obj fn = do
  bracket newChannelPair release \(x, y) -> do
    (handler, proxy) <- atomicallyC $ receiveReference y
    atomicallyC $ setChannelHandler y handler
    liftQuasarIO $ sendReference obj x
    fn proxy
  where
    release :: (NetworkReferenceChannel a, ReverseChannelType (NetworkReferenceChannel a)) -> m ()
    release (x, y) = dispose (getDisposer x <> getDisposer y)
