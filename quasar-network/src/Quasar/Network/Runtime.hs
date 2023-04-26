{-# LANGUAGE UndecidableSuperClasses #-}

module Quasar.Network.Runtime (
  -- * Interacting with objects over network
  NetworkObject(..),
  IsNetworkStrategy(..),
  provideObjectAsMessagePart,
  provideObjectAsDisposableMessagePart,
  receiveObjectFromMessagePart,
  NetworkReference(..),
  NetworkRootReference(..),
) where

import Data.Bifunctor (bimap, first)
import Data.Binary (Binary, encode, decodeOrFail)
import Data.ByteString.Lazy qualified as BSL
import Data.Void (absurd)
import GHC.Generics
import Quasar
import Quasar.Network.Channel
import Quasar.Network.Multiplexer
import Quasar.Prelude

-- * Interacting with objects over network

-- | Describes how a typeclass is used to send- and receive `NetworkObject`s.
type IsNetworkStrategy :: (Type -> Constraint) -> Type -> Constraint
class (s a, NetworkObject a) => IsNetworkStrategy s a where
  -- TODO rename to provide
  provideObject ::
    NetworkStrategy a ~ s =>
    a ->
    Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler))
  receiveObject ::
    NetworkStrategy a ~ s =>
    BSL.ByteString ->
    Either ParseException (Either a (RawChannel -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (RawChannelHandler, a)))

provideObjectAsMessagePart :: NetworkObject a => SendMessageContext -> a -> STMc NoRetry '[] ()
provideObjectAsMessagePart context = addMessagePart context . provideObject

provideObjectAsDisposableMessagePart :: NetworkObject a => SendMessageContext -> a -> STMc NoRetry '[] Disposer
provideObjectAsDisposableMessagePart context x = do
  var <- newTVar mempty
  addMessagePart context do
    case provideObject x of
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
  provideObject x = Left (encode x)
  receiveObject cdata =
    case decodeOrFail cdata of
      -- TODO verify no leftovers
      Left (_leftovers, _position, msg) -> Left (ParseException msg)
      Right (_leftovers, _position, result) -> Right (Left result)


class IsChannel (NetworkReferenceChannel a) => NetworkReference a where
  type NetworkReferenceChannel a
  provideReference :: a -> NetworkReferenceChannel a -> SendMessageContext -> STMc NoRetry '[] (CData (NetworkReferenceChannel a), ChannelHandlerType (NetworkReferenceChannel a))
  receiveReference :: ReceiveMessageContext -> CData (NetworkReferenceChannel a) -> ReverseChannelType (NetworkReferenceChannel a) -> STMc NoRetry '[MultiplexerException] (ReverseChannelHandlerType (NetworkReferenceChannel a), a)

instance (NetworkReference a, NetworkObject a) => IsNetworkStrategy NetworkReference a where
  -- Send an object by reference with the `NetworkReference` class
  provideObject x = Right \channel context -> bimap (encodeCData @(NetworkReferenceChannel a)) (rawChannelHandler @(NetworkReferenceChannel a)) <$> provideReference x (castChannel channel) context
  receiveObject cdata =
    case decodeCData @(NetworkReferenceChannel a) cdata of
      Left ex -> Left ex
      Right parsedCData -> Right $ Right \channel context ->
        first (rawChannelHandler @(ReverseChannelType (NetworkReferenceChannel a))) <$> receiveReference context parsedCData (castChannel channel)


class (IsChannel (NetworkRootReferenceChannel a)) => NetworkRootReference a where
  type NetworkRootReferenceChannel a
  provideRootReference :: a -> NetworkRootReferenceChannel a -> STMc NoRetry '[] (ChannelHandlerType (NetworkRootReferenceChannel a))
  receiveRootReference :: ReverseChannelType (NetworkRootReferenceChannel a) -> STMc NoRetry '[MultiplexerException] (ReverseChannelHandlerType (NetworkRootReferenceChannel a), a)

instance (NetworkRootReference a, NetworkObject a) => IsNetworkStrategy NetworkRootReference a where
  -- Send an object by reference with the `NetworkReference` class
  provideObject x = Right \channel _context -> ("",) . rawChannelHandler @(NetworkRootReferenceChannel a) <$> provideRootReference x (castChannel channel)
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



-- * NetworkObject instances

-- ** Maybe

instance NetworkObject a => NetworkReference (Maybe a) where
  type NetworkReferenceChannel (Maybe a) = Channel () Void Void
  provideReference Nothing channel _context = do
    disposeEventually_ channel
    pure ((), \_ -> absurd)
  provideReference (Just value) _channel context = do
    provideObjectAsMessagePart context value
    pure ((), \_ -> absurd)
  receiveReference context () channel = do
    case context.numCreatedChannels of
      1 -> do
        value <- receiveObjectFromMessagePart context
        pure (\_ -> absurd, Just value)
      _ -> do
        disposeEventually_ channel
        pure (\_ -> absurd, Nothing)

instance NetworkObject a => NetworkObject (Maybe a) where
  type NetworkStrategy (Maybe a) = NetworkReference


-- ** List

instance NetworkObject a => NetworkReference [a] where
  type NetworkReferenceChannel [a] = Channel () Void Void
  provideReference [] channel _context = do
    disposeEventually_ channel
    pure ((), \_ -> absurd)
  provideReference xs _channel context = do
    mapM_ (provideObjectAsMessagePart context) xs
    pure ((), \_ -> absurd)
  receiveReference context () channel = do
    when (context.numCreatedChannels < 1) (disposeEventually_ channel)
    xs <- replicateM context.numCreatedChannels (receiveObjectFromMessagePart context)
    pure (\_ -> absurd, xs)

instance NetworkObject a => NetworkObject [a] where
  type NetworkStrategy [a] = NetworkReference


-- ** Either

instance (NetworkObject a, NetworkObject b) => NetworkReference (Either a b) where
  type NetworkReferenceChannel (Either a b) = Channel (Either () ()) Void Void
  provideReference (Left value) _channel context = do
    provideObjectAsMessagePart context value
    pure (Left (), \_ -> absurd)
  provideReference (Right value) _channel context = do
    provideObjectAsMessagePart context value
    pure (Right (), \_ -> absurd)
  receiveReference context (Left ()) _channel = do
    value <- receiveObjectFromMessagePart context
    pure (\_ -> absurd, Left value)
  receiveReference context (Right ()) _channel = do
    value <- receiveObjectFromMessagePart context
    pure (\_ -> absurd, Right value)

instance (NetworkObject a, NetworkObject b) => NetworkObject (Either a b) where
  type NetworkStrategy (Either a b) = NetworkReference


-- ** Function call

data NetworkFunctionException = NetworkFunctionException
  deriving Show

instance Exception NetworkFunctionException

data NetworkArgument = forall a. NetworkObject a => NetworkArgument a

data NetworkCallRequest = NetworkCallRequest
  deriving Generic
instance Binary NetworkCallRequest

data NetworkCallResponse
  = NetworkCallSuccess
  deriving Generic
instance Binary NetworkCallResponse

class NetworkFunction a where
  handleNetworkFunctionCall :: a -> Channel () NetworkCallResponse Void -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (QuasarIO ())
  networkFunctionProxy :: [NetworkArgument] -> Channel () NetworkCallRequest Void -> a

instance (NetworkObject a, NetworkFunction b) => NetworkFunction (a -> b) where
  handleNetworkFunctionCall fn callChannel callContext = do
    arg <- receiveObjectFromMessagePart callContext
    handleNetworkFunctionCall (fn arg) callChannel callContext
  networkFunctionProxy args functionChannel arg = networkFunctionProxy (args <> [NetworkArgument arg]) functionChannel

instance NetworkObject a => NetworkFunction (IO (FutureEx '[SomeException] a)) where
  handleNetworkFunctionCall fn callChannel _callContext = pure do
    future <- liftIO fn
    async_ do
      result <- await future
      case result of
        Left ex -> do
          -- TODO send exception before closing channel
          disposeEventuallyIO_ callChannel
          throwEx ex
        Right value ->
          sendChannelMessageDeferred_ callChannel \context -> do
            liftSTMc do
              provideObjectAsMessagePart context value
              pure NetworkCallSuccess
  networkFunctionProxy args functionChannel = do
    promise <- newPromiseIO
    sendChannelMessageDeferred_ functionChannel \context -> do
      addChannelMessagePart context \callChannel callContext -> do
        callOnceCompleted_ (isDisposed callChannel) (\() -> tryFulfillPromise_ promise (Left (toEx NetworkFunctionException)))
        forM_ args \(NetworkArgument arg) -> provideObjectAsMessagePart callContext arg
        pure ((), callResponseHandler promise callChannel)
      pure NetworkCallRequest
    pure (toFutureEx promise)
    where
      callResponseHandler :: PromiseEx '[SomeException] a -> Channel () Void NetworkCallResponse -> ChannelHandler NetworkCallResponse
      callResponseHandler promise callChannel responseContext NetworkCallSuccess = do
        result <- atomicallyC $ receiveObjectFromMessagePart responseContext
        tryFulfillPromiseIO_ promise (Right result)
        atomicallyC $ disposeEventually_ callChannel

receiveFunction :: NetworkFunction a => Channel () NetworkCallRequest Void -> STMc NoRetry '[MultiplexerException] (ChannelHandler Void, a)
receiveFunction functionChannel = pure (\_ -> absurd, networkFunctionProxy [] functionChannel)

provideFunction :: NetworkFunction a => a -> Channel () Void NetworkCallRequest -> STMc NoRetry '[] (ChannelHandler NetworkCallRequest)
provideFunction fn _functionChannel = pure \context NetworkCallRequest -> do
  join $ atomically do
    acceptChannelMessagePart context \() callChannel callContext ->
      (\_ -> absurd, ) <$> handleNetworkFunctionCall fn callChannel callContext

instance (NetworkObject a, NetworkFunction b) => NetworkRootReference (a -> b) where
  type NetworkRootReferenceChannel (a -> b) = Channel () Void NetworkCallRequest
  provideRootReference = provideFunction
  receiveRootReference = receiveFunction

instance NetworkObject a => NetworkRootReference (IO (FutureEx '[SomeException] a)) where
  type NetworkRootReferenceChannel (IO (FutureEx '[SomeException] a)) = Channel () Void NetworkCallRequest
  provideRootReference = provideFunction
  receiveRootReference = receiveFunction

instance (NetworkObject a, NetworkFunction b) => NetworkObject (a -> b) where
  type NetworkStrategy (a -> b) = NetworkRootReference

instance NetworkObject a => NetworkObject (IO (FutureEx '[SomeException] a)) where
  type NetworkStrategy (IO (FutureEx '[SomeException] a)) = NetworkRootReference
