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

-- | Low level network protocol control message
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
  multiplexer :: Multiplexer,
  resourceManager :: ResourceManager,
  channelId :: ChannelId
  --connectionState :: ChannelConnectivity,
  --children :: [Channel]
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

newRootChannel :: Multiplexer -> ResourceManagerIO Channel
newRootChannel multiplexer = do
  resourceManager <- askResourceManager
  pure Channel {
    multiplexer,
    resourceManager,
    channelId = 0
  }


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

-- | Starts a new multiplexer on the provided connection and blocks until it is closed.
-- The channel is provided to a setup action and can be closed by calling `dispose`; otherwise the multiplexer will run until the underlying connection is closed.
runMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> (Channel -> ResourceManagerIO ()) -> a -> m ()
runMultiplexer side channelSetupHook connection = do
  rootChannel <- newMultiplexer side connection
  onResourceManager rootChannel $ channelSetupHook rootChannel
  await $ isDisposed rootChannel

-- | Starts a new multiplexer on an existing connection.
-- This starts a thread which runs until 'channelClose' is called on the resulting 'Channel' (use e.g. 'bracket' to ensure the channel is closed).
newMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> a -> m Channel
newMultiplexer side connection = do
  bracketOnError
    newResourceManager
    dispose
    \resourceManager -> onResourceManager resourceManager do
      multiplexer <- startMultiplexer (toSocketConnection connection)
      newRootChannel multiplexer


startMultiplexer :: Connection -> ResourceManagerIO Multiplexer
startMultiplexer connection = do
  inbox <- liftIO newEmptyTMVarIO
  outbox <- liftIO newEmptyTMVarIO
  multiplexerResult <- newAsyncVar

  registerDisposeAction do
    -- Setting `ConnectionClosed` before calling `close` suppresses exceptions from
    -- the send- and receive thread (which might some times occur after closing the socket)
    putAsyncVar_ multiplexerResult ConnectionClosed
    connection.close

  runUnlimitedAsync do
    async_ $ liftIO $ receiveThread inbox `catchAll` (putAsyncVar_ multiplexerResult . ConnectionLost)
    async_ $ liftIO $ sendThread outbox `catchAll` (putAsyncVar_ multiplexerResult . ConnectionLost)

  --channels = HM.empty,
  --sendChannel = 0,
  --receiveChannel = 0,
  --receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
  --sendNextChannelId = if side == MultiplexerSideA then 1 else 2
  pure Multiplexer {
    inbox,
    outbox,
    multiplexerResult
  }
  where
    receiveThread :: TMVar BS.ByteString -> IO ()
    receiveThread inbox = forever do
      chunk <- connection.receive
      atomically $ putTMVar inbox chunk

    sendThread :: TMVar BSL.ByteString -> IO ()
    sendThread outbox = forever do
      chunks <- atomically $ takeTMVar outbox
      connection.send chunks

channelSend :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> (MessageId -> m ()) -> m SentMessageResources
channelSend = undefined

channelSend_ :: MonadIO m => Channel -> MessageConfiguration -> BSL.ByteString -> m SentMessageResources
channelSend_ channel configuration msg = channelSend channel configuration msg (const (pure ()))

channelSendSimple :: MonadIO m => Channel -> BSL.ByteString -> m ()
channelSendSimple channel msg = liftIO do
  -- Pattern match verifies no channels are created due to a bug
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
