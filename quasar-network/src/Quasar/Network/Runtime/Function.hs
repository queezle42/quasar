{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Function (
) where

import Data.Binary (Binary)
import Data.Void (absurd)
import GHC.Generics
import Quasar
import Quasar.Network.Channel
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime.Class
import Quasar.Prelude


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
