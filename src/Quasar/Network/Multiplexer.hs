module Quasar.Network.Multiplexer (
  -- * Channel type
  Channel,

  -- * Sending and receiving messages
  MessageId,
  MessageLength,

  -- ** Sending messages
  MessageConfiguration(..),
  SentMessageResources(..),
  defaultMessageConfiguration,
  channelSend,
  channelSend_,
  channelSendSimple,

  -- ** Receiving messages
  ChannelHandler,
  ChannelMessageHandler,
  ReceivedMessageResources(..),
  channelSetHandler,
  channelSetBinaryHandler,
  channelSetSimpleBinaryHandler,

  -- ** Exception handling
  MultiplexerException(..),
  ChannelException(..),
  channelReportProtocolError,
  channelReportException,

  -- * Create or run a multiplexer
  MultiplexerSide(..),
  runMultiplexer,
  newMultiplexer,
) where


import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad.Catch
import Data.Bifunctor (first)
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
type NewChannelCount = Word32

-- ** Wire format

magicBytes :: BS.ByteString
magicBytes = "qso\0dev\0"

-- | Low level network protocol control message
data MultiplexerMessage
  = ChannelMessage NewChannelCount MessageLength
  | SwitchChannel ChannelId
  | CloseChannel
  | MultiplexerProtocolError String
  | ChannelProtocolError ChannelId String
  | InternalError String
  deriving stock (Generic, Show)
  deriving anyclass (Binary)


-- ** Multiplexer

data Multiplexer = Multiplexer {
  inbox :: TMVar (BS.ByteString),
  outbox :: TMVar (BSL.ByteString),
  multiplexerResult :: AsyncVar MultiplexerException,
  channelsVar :: TVar (HM.HashMap ChannelId Channel)
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
  | InvalidMagicBytes BS.ByteString
  | LocalException SomeException
  | RemoteException String
  | ProtocolException String
  | ReceivedProtocolException String
  | ChannelProtocolException ChannelId String
  | ReceivedChannelProtocolException ChannelId String
  deriving stock Show

instance Exception MultiplexerException where
  displayException (InvalidMagicBytes received) =
    mconcat ["Magic bytes don't match: Expected ", show magicBytes, ", got ", show received]
  displayException ex = show ex

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


data ChannelException = ChannelNotConnected
  deriving stock Show
  deriving anyclass Exception

-- ** Channel message interface

type ChannelHandler = MessageLength -> ReceivedMessageResources -> ResourceManagerIO ChannelMessageHandler
type ChannelMessageHandler = Maybe BS.ByteString -> ResourceManagerIO ()

newtype MessageConfiguration = MessageConfiguration {
  createChannels :: NewChannelCount
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

-- | Starts a new multiplexer on an existing connection (e.g. on a connected TCP socket).
newMultiplexer :: (IsConnection a, MonadResourceManager m) => MultiplexerSide -> a -> m Channel
newMultiplexer side (toSocketConnection -> connection) = liftResourceManagerIO $ disposeOnError do
  -- The multiplexer returned by `askResourceManager` is created by `disposeOnError`, so it can be used as a disposable
  -- without accidentally disposing external resources.
  resourceManager <- askResourceManager

  inbox <- liftIO newEmptyTMVarIO
  outbox <- liftIO $ newTMVarIO $ BSL.fromStrict magicBytes
  multiplexerResult <- newAsyncVar

  registerDisposeAction do
    -- Setting `ConnectionClosed` before calling `close` suppresses exceptions from
    -- the send- and receive thread (which occur after closing the socket)
    putAsyncVar_ multiplexerResult ConnectionClosed
    connection.close

  handleAsync_ (putAsyncVar_ multiplexerResult . ConnectionLost) (liftIO (receiveThread inbox))
  handleAsync_ (putAsyncVar_ multiplexerResult . ConnectionLost) (liftIO (sendThread outbox))

  -- An async cannot be disposed from its own thread, so forkIO is used instead for now
  liftIO $ void $ forkIO do
    awaitSuccessOrFailure multiplexerResult
    -- Ensure the multiplexer is disposed when the connection is lost
    disposeEventually_ resourceManager

  mfix \rootChannel -> do
    channelsVar <- liftIO $ newTVarIO $ HM.singleton 0 rootChannel

    --sendChannel = 0,
    --receiveChannel = 0,
    --receiveNextChannelId = if side == MultiplexerSideA then 2 else 1,
    --sendNextChannelId = if side == MultiplexerSideA then 1 else 2
    let multiplexer = Multiplexer {
      inbox,
      outbox,
      multiplexerResult,
      channelsVar
    }

    handleAsync_ (multiplexerExceptionHandler multiplexer) (liftIO (multiplexerThread multiplexer))

    newRootChannel multiplexer
  where
    receiveThread :: TMVar BS.ByteString -> IO ()
    receiveThread inbox = forever do
      chunk <- connection.receive
      atomically $ putTMVar inbox chunk

    sendThread :: TMVar BSL.ByteString -> IO ()
    sendThread outbox = forever do
      chunks <- atomically $ takeTMVar outbox
      connection.send chunks

multiplexerExceptionHandler :: Multiplexer -> SomeException -> IO ()
-- Exception is a MultiplexerException already
multiplexerExceptionHandler m (fromException -> Just ex) = putAsyncVar_ m.multiplexerResult ex
-- Exception is an unexpected exception
multiplexerExceptionHandler m ex = putAsyncVar_ m.multiplexerResult $ LocalException ex

multiplexerThread :: Multiplexer -> IO ()
multiplexerThread multiplexer = checkMagicBytes =<< read
  where
    read :: IO BS.ByteString
    read = atomically $ takeTMVar multiplexer.inbox

    continueWithMoreData :: (BS.ByteString -> IO ()) -> BS.ByteString -> IO ()
    continueWithMoreData messageHandler leftovers = messageHandler . (leftovers <>) =<< read

    checkMagicBytes :: BS.ByteString -> IO ()
    checkMagicBytes chunk@((< magicBytesLength) . BS.length -> True) =
      continueWithMoreData checkMagicBytes chunk
    checkMagicBytes (BS.splitAt magicBytesLength -> (bytes, leftovers)) =
      if bytes == magicBytes
        then nextMultiplexerMessage leftovers
        else throwM $ InvalidMagicBytes $ bytes

    magicBytesLength = BS.length magicBytes

    nextMultiplexerMessage :: BS.ByteString -> IO ()
    nextMultiplexerMessage leftovers = stepDecoder (pushChunk (runGetIncremental Binary.get) leftovers)
      where
        stepDecoder :: Decoder MultiplexerMessage -> IO ()
        stepDecoder (Fail _ _ errMsg) = throwM $ ProtocolException $ "Failed to parse protocol message: " <> errMsg
        stepDecoder (Partial feedFn) = stepDecoder . feedFn . Just =<< read
        stepDecoder (Done leftovers _ msg) = execMultiplexerMessage msg leftovers

    execMultiplexerMessage :: MultiplexerMessage -> BS.ByteString -> IO ()
    execMultiplexerMessage multiplexerMessage leftovers =
      case multiplexerMessage of
        (ChannelMessage channelAmount messageLength) -> undefined
        (SwitchChannel channelId) -> undefined
        CloseChannel -> undefined
        (MultiplexerProtocolError msg) -> throwM $ RemoteException $ "Remote closed connection because of a multiplexer protocol error: " <> msg
        (ChannelProtocolError channelId msg) -> throwM $ ChannelProtocolException channelId msg
        (InternalError msg) -> throwM $ RemoteException msg
      where
        continue = nextMultiplexerMessage leftovers

    receiveChannelMessage :: MessageLength -> BS.ByteString -> IO ()
    receiveChannelMessage remaining chunk = undefined

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
channelSetHandler = undefined

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (ReceivedMessageResources -> a -> ResourceManagerIO ()) -> m ()
channelSetBinaryHandler = undefined

-- | Sets a simple channel message handler, which cannot handle sub-resurces (e.g. new channels). When a resource is received the channel will be terminated with a channel protocol error.
channelSetSimpleBinaryHandler :: forall a m. (Binary a, MonadIO m) => Channel -> (a -> ResourceManagerIO ()) -> m ()
channelSetSimpleBinaryHandler = undefined
