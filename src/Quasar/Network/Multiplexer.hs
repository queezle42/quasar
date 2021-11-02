module Quasar.Network.Multiplexer (
  MessageId,
  MessageLength,
  Channel,
  MessageConfiguration(..),
  defaultMessageConfiguration,
  SentMessageResources(..),
  ReceivedMessageResources(..),
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,
  channelSend,
  channelSend_,
  channelSendSimple,
  channelSetHandler,
  channelSetBinaryHandler,
  channelSetSimpleBinaryHandler,
  ChannelMessageHandler,

  -- * Multiplexer
  MultiplexerException(..),
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Data.Binary (Binary, encode)
import Data.Binary qualified as Binary
import Data.Binary.Get (Get, Decoder(..), runGetIncremental, pushChunk, pushEndOfInput)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.HashMap.Strict qualified as HM
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Connection
import Quasar.Prelude
import Quasar.ResourceManager
import System.IO (hPutStrLn, stderr)

-- * Types

-- | Designed for long-running processes
type ChannelId = Word64
type MessageId = Word64
type MessageLength = Word64

-- | Amount of created sub-channels
type ChannelAmount = Word32

-- ** Wire format

-- | Low level network protocol message type
data MultiplexerMessage
  = ChannelMessage ChannelAmount MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | ProtocolError String
  | ChannelProtocolError ChannelId String
  deriving stock (Generic, Show)
  deriving anyclass (Binary)


-- ** Multiplexer

data Multiplexer = Multiplexer {
  inbox :: TMVar (BS.ByteString),
  outbox :: TMVar (BSL.ByteString),
  multiplexerResult :: AsyncVar MultiplexerException
  --channels :: HM.HashMap ChannelId Channel,
  --sendChannel :: ChannelId,
  --receiveChannel :: ChannelId,
  --receiveNextChannelId :: ChannelId,
  --sendNextChannelId :: ChannelId
}

data MultiplexerSide = MultiplexerSideA | MultiplexerSideB
  deriving stock (Eq, Show)

data MultiplexerException
  = ConnectionClosed
  | ConnectionLost SomeException
  | LocalException SomeException
  | RemoteException String
  | ProtocolException String
  | ChannelProtocolException ChannelId String
  deriving stock Show
  deriving anyclass Exception

-- ** Channel

data Channel = Channel {
  channelId :: ChannelId,
  resourceManager :: ResourceManager,
  closingVar :: TVar Bool,
  closedVar :: TVar Bool
  --connectionState :: ChannelConnectivity,
  --children :: [Channel]
  --multiplexer :: Multiplexer,
  --stateMVar :: MVar ChannelState,
  --sendStateMVar :: MVar ChannelSendState,
    --  nextMessageId :: MessageId
  --receiveStateMVar :: MVar ChannelReceiveState,
    --  nextMessageId :: MessageId
  --handlerAtVar :: AtVar InternalChannelMessageHandler
}

instance IsDisposable Channel where
  toDisposable channel = toDisposable channel.resourceManager

instance IsResourceManager Channel where
  toResourceManager channel = channel.resourceManager


type ChannelHandler = MessageLength -> ReceivedMessageResources -> ResourceManagerIO ChannelMessageHandler
type ChannelMessageHandler = Maybe BS.ByteString -> ResourceManagerIO ()


data ChannelException = ChannelNotConnected
  deriving stock Show
  deriving anyclass Exception


-- ** Channel message interface

newtype MessageConfiguration = MessageConfiguration {
  createChannels :: ChannelAmount
}

defaultMessageConfiguration :: MessageConfiguration
defaultMessageConfiguration = MessageConfiguration {
  createChannels = 0
}

data SentMessageResources = SentMessageResources {
  messageId :: MessageId,
  createdChannels :: [Channel]
  --unixFds :: Undefined
}
data ReceivedMessageResources = ReceivedMessageResources {
  messageId :: MessageId,
  createdChannels :: [Channel]
  --unixFds :: Undefined
}


-- * Implementation

-- | Starts a new multiplexer on an existing connection.
-- This starts a thread which runs until 'channelClose' is called on the resulting 'Channel' (use e.g. 'bracket' to ensure the channel is closed).
newMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> a -> m Channel
newMultiplexer side connection = do
  channelMVar <- liftIO newEmptyMVar
  runUnlimitedAsync $ async_ $ runMultiplexer side (liftIO . putMVar channelMVar) (toSocketConnection connection)
  liftIO $ takeMVar channelMVar

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling `dispose`; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> (Channel -> m ()) -> a -> m ()
runMultiplexer side channelSetupHook connection = withSubResourceManagerM do
  --channels = HM.empty,
  --sendChannel = 0,
  --receiveChannel = 0,
  --receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
  --sendNextChannelId = if side == MultiplexerSideA then 1 else 2

  inbox <- liftIO newEmptyTMVarIO
  outbox <- liftIO newEmptyTMVarIO
  multiplexerResult <- newAsyncVar

  let
    multiplexer = Multiplexer {
      inbox,
      outbox,
      multiplexerResult
    }

  runUnlimitedAsync do
    async_ $ liftIO $ receiveThread inbox
    async_ $ liftIO $ sendThread outbox

  resourceManager <- askResourceManager

  --rootChannel <- withMultiplexerState multiplexer (newChannel resourceManager multiplexer 0 Connected)
  rootChannel <- undefined

  channelSetupHook rootChannel

  undefined

  where
    socketConnection :: Connection
    socketConnection = toSocketConnection connection

    receiveThread :: TMVar BS.ByteString -> IO ()
    receiveThread inbox = forever do
      chunk <- socketConnection.receive
      atomically $ putTMVar inbox chunk
      -- TODO report error

    sendThread :: TMVar BSL.ByteString -> IO ()
    sendThread outbox = forever do
      chunks <- atomically $ takeTMVar outbox
      socketConnection.send chunks
      -- TODO `catch` \ex -> throwIO =<< multiplexerClose (ConnectionLost ex) multiplexer

channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> m ()) -> m SentMessageResources
channelSend = undefined

channelSend_ :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> m SentMessageResources
channelSend_ channel configuration msg = channelSend channel configuration msg (const (pure ()))

channelSendSimple :: MonadIO m => Channel -> BSL.ByteString -> m ()
channelSendSimple channel msg = liftIO do
  -- We are not sending headers, so no channels can be created
  SentMessageResources{createdChannels=[]} <- channelSend channel defaultMessageConfiguration msg (const (pure ()))
  pure ()

channelReportProtocolError :: MonadIO m => Channel -> String -> m b
channelReportProtocolError = undefined

channelReportException :: MonadIO m => Channel -> SomeException -> m b
channelReportException = undefined


channelSetHandler :: MonadIO m => Channel -> ChannelHandler -> m ()
channelSetHandler = undefined -- TODO new type

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (ReceivedMessageResources -> a -> ResourceManagerIO ()) -> m ()
channelSetBinaryHandler = undefined

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetSimpleBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (a -> ResourceManagerIO ()) -> m ()
channelSetSimpleBinaryHandler = undefined
