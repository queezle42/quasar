{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Future () where

import Control.Monad.Catch
import Data.Binary (Binary)
import Data.Void (absurd)
import Quasar
import Quasar.Network.Channel
import Quasar.Network.Runtime.Class
import Quasar.Prelude


data FutureMessage
  = FutureValue
  deriving stock Generic

instance Binary FutureMessage

data NetworkFutureException = NetworkFutureException
  deriving Show

instance Exception NetworkFutureException


instance NetworkObject a => NetworkRootReference (FutureEx '[SomeException] a) where
  type NetworkRootReferenceChannel (FutureEx '[SomeException] a) = Channel () FutureMessage Void
  provideRootReference future channel = do
    execForeignQuasarSTMc @NoRetry channel.quasar do
      asyncSTM_ do
        result <- await (tryAllC future)
        case result of
          Left _ex -> do
            -- TODO send exception before closing channel
            disposeEventuallyIO_ channel
          Right value ->
            sendChannelMessageDeferred_ channel \context -> do
              liftSTMc do
                provideObjectAsMessagePart context value
                pure FutureValue
    pure (\_ -> absurd)
  receiveRootReference channel = do
    promise <- newPromise
    callOnceCompleted_ (isDisposed channel) (\_ -> tryFulfillPromise_ promise (Left (toEx NetworkFutureException)))
    pure (futureHandler promise, toFutureEx promise)
    where
      futureHandler :: PromiseEx '[SomeException] a -> ChannelHandler FutureMessage
      futureHandler promise context FutureValue = do
        result <- atomicallyC $ receiveObjectFromMessagePart context
        tryFulfillPromiseIO_ promise (Right result)

instance NetworkObject a => NetworkObject (FutureEx '[SomeException] a) where
  type NetworkStrategy (FutureEx '[SomeException] a) = NetworkRootReference
