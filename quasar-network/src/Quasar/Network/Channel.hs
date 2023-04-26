{-# LANGUAGE UndecidableSuperClasses #-}
module Quasar.Network.Channel (
  -- * Channel
  IsChannel(..),
  addChannelMessagePart,
  addDataMessagePart,
  newChannelPair,
  ReverseChannelHandlerType,

  -- ** `Binary`-based channel
  Channel,
  channelSend,
  sendChannelMessageDeferred,
  sendChannelMessageDeferred_,
  unsafeQueueChannelMessage,

  ChannelHandler,
  channelSetHandler,
  channelSetSimpleHandler,
  acceptChannelMessagePart,
  acceptDataMessagePart,
) where

import Data.Bifunctor (bimap, first)
import Data.Binary (Binary, encode, decodeOrFail)
import Data.ByteString.Lazy qualified as BSL
import GHC.Records
import Quasar
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude

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


newChannelPair :: (IsChannel a, MonadQuasar m, MonadIO m) => m (a, ReverseChannelType a)
newChannelPair = liftQuasarIO do
  (clientConnection, serverConnection) <- newConnectionPair
  clientChannel <- newMultiplexer MultiplexerSideA clientConnection
  serverChannel <- newMultiplexer MultiplexerSideB serverConnection
  pure (castChannel clientChannel, castChannel serverChannel)

