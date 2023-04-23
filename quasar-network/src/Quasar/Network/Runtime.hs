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
  sendChannelMessageDeferred_,
  addChannelMessagePart,
  addDataMessagePart,

  ChannelHandler,
  channelSetHandler,
  channelSetSimpleHandler,
  acceptChannelMessagePart,
  acceptDataMessagePart,

  unsafeQueueChannelMessage,
  newChannelPair,

  -- * Test implementation
  --withStandaloneClient,
  withStandaloneProxy,

  -- * Interacting with objects over network
  NetworkObject(..),
  IsNetworkStrategy(..),
  sendObjectAsMessagePart,
  sendObjectAsDisposableMessagePart,
  receiveObjectFromMessagePart,
  NetworkReference(..),
  NetworkRootReference(..),
  IsChannel(..),
) where

import Control.Monad.Catch
import Data.Bifunctor (bimap, first)
import Data.Binary (Binary, encode, decodeOrFail)
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import GHC.Records
import Network.Socket qualified as Socket
import Quasar
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import Quasar.Utils.HashMap qualified as HM
import System.Posix.Files (getFileStatus, isSocket, fileExist, removeLink)
import Data.Void (absurd)

-- * Interacting with objects over network


type IsChannel :: Type -> Constraint
class (IsChannel (ReverseChannelType a), a ~ ReverseChannelType (ReverseChannelType a), Disposable a) => IsChannel a where
  type ReverseChannelType a
  type CData a :: Type
  type ChannelHandlerType a
  castChannel :: RawChannel -> a
  encodeCData :: CData a -> BSL.ByteString
  decodeCData :: BSL.ByteString -> Either ParseException (CData a)
  rawChannelHandler :: ChannelHandlerType a -> RawChannelHandler
  setChannelHandler :: a -> ChannelHandlerType a -> STMc NoRetry '[] ()

instance IsChannel RawChannel where
  type ReverseChannelType RawChannel = RawChannel
  type CData RawChannel = BSL.ByteString
  type ChannelHandlerType RawChannel = RawChannelHandler
  castChannel = id
  encodeCData = id
  decodeCData = Right
  rawChannelHandler = id
  setChannelHandler = rawChannelSetHandler


instance (Binary cdata, Binary up, Binary down) => IsChannel (Channel cdata up down) where
  type ReverseChannelType (Channel cdata up down) = (Channel cdata down up)
  type CData (Channel cdata up down) = cdata
  type ChannelHandlerType (Channel cdata up down) = ChannelHandler down
  castChannel = Channel
  encodeCData = encode
  decodeCData cdata =
    case decodeOrFail cdata of
      Right ("", _position, parsedCData) -> Right parsedCData
      Right (leftovers, _position, _parsedCData) -> Left (ParseException (mconcat ["Failed to parse channel cdata: ", show (BSL.length leftovers), "b leftover data"]))
      Left (_leftovers, _position, msg) -> Left (ParseException msg)
  rawChannelHandler = binaryHandler
  setChannelHandler (Channel channel) handler = rawChannelSetHandler channel (binaryHandler handler)

type ReverseChannelHandlerType a = ChannelHandlerType (ReverseChannelType a)

type ChannelHandler a = ReceiveMessageContext -> a -> QuasarIO ()

addChannelMessagePart :: forall channel m.
  (IsChannel channel, MonadSTMc NoRetry '[] m) =>
  SendMessageContext ->
  (
    channel ->
    SendMessageContext ->
    STMc NoRetry '[] (CData channel, ChannelHandlerType channel)
  ) ->
  m ()
addChannelMessagePart context initChannelFn = liftSTMc do
  addRawChannelMessagePart context (\rawChannel channelContext -> bimap (encodeCData @channel) (rawChannelHandler @channel) <$> initChannelFn (castChannel rawChannel) channelContext)

acceptChannelMessagePart :: forall channel m a.
  (IsChannel channel, MonadSTMc NoRetry '[MultiplexerException] m) =>
  ReceiveMessageContext ->
  (
    CData channel ->
    channel ->
    ReceiveMessageContext ->
    STMc NoRetry '[MultiplexerException] (ChannelHandlerType channel, a)
  ) ->
  m a
acceptChannelMessagePart context fn = liftSTMc do
  acceptRawChannelMessagePart context \cdata ->
    case decodeCData @channel cdata of
      Left ex -> Left ex
      Right parsedCData -> Right \channel channelContext -> do
        first (rawChannelHandler @channel) <$> fn parsedCData (castChannel channel) channelContext

-- | Describes how a typeclass is used to send- and receive `NetworkObject`s.
type IsNetworkStrategy :: (Type -> Constraint) -> Type -> Constraint
class (s a, NetworkObject a) => IsNetworkStrategy s a where
  -- TODO rename to provide
  sendObject ::
    NetworkStrategy a ~ s =>
    a ->
    Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler))
  receiveObject ::
    NetworkStrategy a ~ s =>
    BSL.ByteString ->
    Either ParseException (Either a (RawChannel -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (RawChannelHandler, a)))

sendObjectAsMessagePart :: NetworkObject a => SendMessageContext -> a -> STMc NoRetry '[] ()
sendObjectAsMessagePart context = addMessagePart context . sendObject

sendObjectAsDisposableMessagePart :: NetworkObject a => SendMessageContext -> a -> STMc NoRetry '[] Disposer
sendObjectAsDisposableMessagePart context x = do
  var <- newTVar mempty
  addMessagePart context do
    case sendObject x of
      Left cdata -> Left cdata
      Right fn -> Right \newChannel newContext -> do
        writeTVar var (getDisposer newChannel)
        fn newChannel newContext
  readTVar var

receiveObjectFromMessagePart :: NetworkObject a => ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] a
receiveObjectFromMessagePart context = acceptMessagePart context receiveObject

class IsNetworkStrategy (NetworkStrategy a) a => NetworkObject a where
  type NetworkStrategy a :: (Type -> Constraint)


instance (Binary a, NetworkObject a) => IsNetworkStrategy Binary a where
  sendObject x = Left (encode x)
  receiveObject cdata =
    case decodeOrFail cdata of
      -- TODO verify no leftovers
      Left (_leftovers, _position, msg) -> Left (ParseException msg)
      Right (_leftovers, _position, result) -> Right (Left result)


class IsChannel (NetworkReferenceChannel a) => NetworkReference a where
  type NetworkReferenceChannel a
  sendReference :: a -> NetworkReferenceChannel a -> SendMessageContext -> STMc NoRetry '[] (CData (NetworkReferenceChannel a), ChannelHandlerType (NetworkReferenceChannel a))
  receiveReference :: ReceiveMessageContext -> CData (NetworkReferenceChannel a) -> ReverseChannelType (NetworkReferenceChannel a) -> STMc NoRetry '[MultiplexerException] (ReverseChannelHandlerType (NetworkReferenceChannel a), a)

instance (NetworkReference a, NetworkObject a) => IsNetworkStrategy NetworkReference a where
  -- Send an object by reference with the `NetworkReference` class
  sendObject x = Right \channel context -> bimap (encodeCData @(NetworkReferenceChannel a)) (rawChannelHandler @(NetworkReferenceChannel a)) <$> sendReference x (castChannel channel) context
  receiveObject cdata =
    case decodeCData @(NetworkReferenceChannel a) cdata of
      Left ex -> Left ex
      Right parsedCData -> Right $ Right \channel context ->
        first (rawChannelHandler @(ReverseChannelType (NetworkReferenceChannel a))) <$> receiveReference context parsedCData (castChannel channel)


class (IsChannel (NetworkRootReferenceChannel a)) => NetworkRootReference a where
  type NetworkRootReferenceChannel a
  sendRootReference :: a -> NetworkRootReferenceChannel a -> STMc NoRetry '[] (ChannelHandlerType (NetworkRootReferenceChannel a))
  receiveRootReference :: ReverseChannelType (NetworkRootReferenceChannel a) -> STMc NoRetry '[MultiplexerException] (ReverseChannelHandlerType (NetworkRootReferenceChannel a), a)

instance (NetworkRootReference a, NetworkObject a) => IsNetworkStrategy NetworkRootReference a where
  -- Send an object by reference with the `NetworkReference` class
  sendObject x = Right \channel _context -> ("",) . rawChannelHandler @(NetworkRootReferenceChannel a) <$> sendRootReference x (castChannel channel)
  receiveObject "" = Right $ Right \channel _context -> first (rawChannelHandler @(ReverseChannelType (NetworkRootReferenceChannel a))) <$> receiveRootReference (castChannel channel)
  receiveObject cdata = Left (ParseException (mconcat ["Received ", show (BSL.length cdata), " bytes of constructor data (0 bytes expected)"]))


instance NetworkObject () where
  type NetworkStrategy () = Binary

instance NetworkObject Bool where
  type NetworkStrategy Bool = Binary

instance NetworkObject Int where
  type NetworkStrategy Int = Binary

instance NetworkObject Float where
  type NetworkStrategy Float = Binary

instance NetworkObject Double where
  type NetworkStrategy Double = Binary

instance NetworkObject Char where
  type NetworkStrategy Char = Binary



type Channel :: Type -> Type -> Type -> Type
newtype Channel cdata up down = Channel RawChannel
  deriving newtype Disposable

instance HasField "quasar" (Channel cdata up down) Quasar where
  getField (Channel rawChannel) = rawChannel.quasar

channelSend :: (Binary up, MonadIO m) => Channel cdata up down -> up -> m ()
channelSend (Channel channel) value = liftIO $ sendRawChannelMessage channel (encode value)

sendChannelMessageDeferred :: (Binary up, MonadIO m) => Channel cdata up down -> (SendMessageContext -> STMc NoRetry '[AbortSend] (up, a)) -> m a
sendChannelMessageDeferred (Channel channel) payloadHook = sendRawChannelMessageDeferred channel (first encode <<$>> payloadHook)

sendChannelMessageDeferred_ :: (Binary up, MonadIO m) => Channel cdata up down -> (SendMessageContext -> STMc NoRetry '[AbortSend] up) -> m ()
sendChannelMessageDeferred_ channel payloadHook = sendChannelMessageDeferred channel ((,()) <<$>> payloadHook)

unsafeQueueChannelMessage :: (Binary up, MonadSTMc NoRetry '[AbortSend, ChannelException, MultiplexerException] m) => Channel cdata up down -> up -> m ()
unsafeQueueChannelMessage (Channel channel) value =
  unsafeQueueRawChannelMessage channel (encode value)

channelSetHandler :: (Binary down, MonadSTMc NoRetry '[] m) => Channel cdata up down -> ChannelHandler down -> m ()
channelSetHandler (Channel s) fn = rawChannelSetHandler s (binaryHandler fn)

channelSetSimpleHandler :: (Binary down, MonadSTMc NoRetry '[] m) => Channel cdata up down -> (down -> QuasarIO ()) -> m ()
channelSetSimpleHandler (Channel channel) fn = rawChannelSetHandler channel (simpleBinaryHandler fn)

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

withStandaloneProxy :: forall a m b. (NetworkRootReference a, MonadQuasar m, MonadIO m, MonadMask m) => a -> (a -> m b) -> m b
withStandaloneProxy obj fn = do
  bracket newChannelPair release \(x, y) -> do
    handlerX <- atomicallyC $ sendRootReference obj x
    atomicallyC $ setChannelHandler x handlerX
    (handlerY, proxy) <- atomicallyC $ receiveRootReference y
    atomicallyC $ setChannelHandler y handlerY
    fn proxy
  where
    release :: (NetworkRootReferenceChannel a, ReverseChannelType (NetworkRootReferenceChannel a)) -> m ()
    release (x, y) = dispose (getDisposer x <> getDisposer y)


-- * NetworkObject instances

-- ** Function call

data NetworkArgument = forall a. NetworkObject a => NetworkArgument a

data NetworkCallRequest = NetworkCallRequest
  deriving Generic
instance Binary NetworkCallRequest

data NetworkCallResponse = NetworkCallSuccess
  deriving Generic
instance Binary NetworkCallResponse

class NetworkFunction a where
  networkFunctionFoobar :: a -> Channel () NetworkCallResponse Void -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (QuasarIO ())
  networkFunctionProxy :: [NetworkArgument] -> Channel () NetworkCallRequest Void -> a

instance (NetworkObject a, NetworkFunction b) => NetworkFunction (a -> b) where
  networkFunctionFoobar fn channel context = do
    arg <- receiveObjectFromMessagePart context
    networkFunctionFoobar (fn arg) channel context
  networkFunctionProxy args channel arg = networkFunctionProxy (args <> [NetworkArgument arg]) channel

instance NetworkObject a => NetworkFunction (IO (Future a)) where
  networkFunctionFoobar fn channel _context = pure do
    future <- liftIO fn
    async_ do
      result <- await future
      -- TODO FutureEx handling: send exception before closing the channel
      sendChannelMessageDeferred_ channel \context -> do
        liftSTMc do
          sendObjectAsMessagePart context result
          pure NetworkCallSuccess
  networkFunctionProxy args channel = do
    promise <- newPromiseIO
    sendChannelMessageDeferred_ channel \context -> do
      addChannelMessagePart context \callChannel callContext -> do
        forM_ args \(NetworkArgument arg) -> sendObjectAsMessagePart callContext arg
        pure ((), channelHandler promise callChannel)
      pure NetworkCallRequest
    pure (toFuture promise)
    where
      channelHandler :: Promise a -> Channel () Void () -> ChannelHandler ()
      channelHandler promise callChannel context () = do
        result <- atomicallyC $ receiveObjectFromMessagePart context
        tryFulfillPromiseIO_ promise result
        atomicallyC $ disposeEventually_ callChannel

receiveFunction :: NetworkFunction a => Channel () NetworkCallRequest Void -> STMc NoRetry '[MultiplexerException] (ChannelHandler Void, a)
receiveFunction channel = pure (\_ -> absurd, networkFunctionProxy [] channel)

provideFunction :: NetworkFunction a => a -> Channel () Void NetworkCallRequest -> STMc NoRetry '[] (ChannelHandler NetworkCallRequest)
provideFunction fn _channel = pure \context NetworkCallRequest -> join $ atomically do
  acceptChannelMessagePart context \() callChannel callContext ->
    (\_ -> absurd, ) <$> networkFunctionFoobar fn callChannel callContext

instance (NetworkObject a, NetworkFunction b) => NetworkRootReference (a -> b) where
  type NetworkRootReferenceChannel (a -> b) = Channel () Void NetworkCallRequest
  sendRootReference = provideFunction
  receiveRootReference = receiveFunction

instance NetworkObject a => NetworkRootReference (IO (Future a)) where
  type NetworkRootReferenceChannel (IO (Future a)) = Channel () Void NetworkCallRequest
  sendRootReference = provideFunction
  receiveRootReference = receiveFunction

instance (NetworkObject a, NetworkFunction b) => NetworkObject (a -> b) where
  type NetworkStrategy (a -> b) = NetworkRootReference

instance NetworkObject a => NetworkObject (IO (Future a)) where
  type NetworkStrategy (IO (Future a)) = NetworkRootReference
