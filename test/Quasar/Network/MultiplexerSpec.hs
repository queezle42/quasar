module Quasar.Network.MultiplexerSpec (spec) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar
import Control.Monad.Catch
import Data.ByteString.Lazy qualified as BSL
import Quasar
import Quasar.Network.Multiplexer
import Quasar.Network.Connection
import Quasar.Prelude
import Test.Hspec.Core.Spec
import Test.Hspec.Expectations.Lifted
import Test.Hspec qualified as Hspec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions (stderrLogger LogLevelWarning)

shouldThrow :: (HasCallStack, Exception e, MonadQuasar m, MonadIO m) => QuasarIO a -> Hspec.Selector e -> m ()
shouldThrow action expected = do
  quasar <- askQuasar
  liftIO $ runQuasarIO quasar action `Hspec.shouldThrow` expected

spec :: Spec
spec = parallel $ describe "runMultiplexer" $ do
  it "can be closed from the channelSetupHook" do
    (x, y) <- newConnectionPair
    concurrently_
      do rm (runMultiplexer MultiplexerSideA dispose x)
      do rm (runMultiplexer MultiplexerSideB dispose y)

  it "closes when the remote is closed" do
    (x, y) <- newConnectionPair
    concurrently_
      do rm (runMultiplexer MultiplexerSideA (\rootChannel -> await (isDisposed rootChannel)) x)
      do rm (runMultiplexer MultiplexerSideB dispose y)

  it "will dispose an attached resource" $ rm do
    var <- newPromise
    (x, y) <- newConnectionPair
    void $ newMultiplexer MultiplexerSideB y
    runMultiplexer
      do MultiplexerSideA
      do
        \channel -> do
          runQuasarIO channel.quasar $ registerDisposeTransactionIO_ (fulfillPromiseSTM var ())
          dispose channel
      do x
    peekFuture (await var) `shouldReturn` Just ()

  it "can send and receive simple messages" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetSimpleHandler channel ((liftIO . putMVar recvMVar) :: BSL.ByteString -> QuasarIO ())
      channelSendSimple channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"
      channelSendSimple channel "test"
      liftIO $ takeMVar recvMVar `shouldReturn` "test"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can create sub-channels" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel ((\_ -> liftIO . putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> QuasarIO ())
      SentMessageResources{createdChannels=[_]} <- channelSend_ channel defaultMessageConfiguration{createChannels=1} "create a channel"
      liftIO $ takeMVar recvMVar `shouldReturn` "create a channel"
      SentMessageResources{createdChannels=[_, _, _]} <- channelSend_ channel defaultMessageConfiguration{createChannels=3} "create more channels"
      liftIO $ takeMVar recvMVar `shouldReturn` "create more channels"
    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can send messages on sub-channels" $ do
    recvMVar <- newEmptyMVar
    c1RecvMVar <- newEmptyMVar
    c2RecvMVar <- newEmptyMVar
    c3RecvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetSimpleHandler channel $ (liftIO . putMVar recvMVar :: BSL.ByteString -> QuasarIO ())
      channelSendSimple channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"

      SentMessageResources{createdChannels=[c1, c2]} <- channelSend_ channel defaultMessageConfiguration{createChannels=2}  "create channels"
      liftIO $ takeMVar recvMVar `shouldReturn` "create channels"
      channelSetSimpleHandler c1 (liftIO . putMVar c1RecvMVar :: BSL.ByteString -> QuasarIO ())
      channelSetSimpleHandler c2 (liftIO . putMVar c2RecvMVar :: BSL.ByteString -> QuasarIO ())

      channelSendSimple c1 "test"
      liftIO $ takeMVar c1RecvMVar `shouldReturn` "test"
      channelSendSimple c2 "test2"
      liftIO $ takeMVar c2RecvMVar `shouldReturn` "test2"
      channelSendSimple c2 "test3"
      liftIO $ takeMVar c2RecvMVar `shouldReturn` "test3"
      channelSendSimple c1 "test4"
      liftIO $ takeMVar c1RecvMVar `shouldReturn` "test4"

      SentMessageResources{createdChannels=[c3]} <- channelSend_ channel  defaultMessageConfiguration{createChannels=1} "create another channel"
      liftIO $ takeMVar recvMVar `shouldReturn` "create another channel"
      channelSetSimpleHandler c3 (liftIO . putMVar c3RecvMVar :: BSL.ByteString -> QuasarIO ())

      channelSendSimple c3 "test5"
      liftIO $ takeMVar c3RecvMVar `shouldReturn` "test5"
      channelSendSimple c1 "test6"
      liftIO $ takeMVar c1RecvMVar `shouldReturn` "test6"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can terminate a connection when the connection backend hangs" $ rm do
    liftIO $ pendingWith "This test cannot work with the current implementation"
    msgSentMVar <- liftIO newEmptyMVar
    let
      connection = Connection {
        description = "hanging test connection",
        send = const (putMVar msgSentMVar () >> sleepForever),
        receive = sleepForever,
        close = pure ()
      }
      testAction :: Channel -> IO ()
      testAction channel = concurrently_ (channelSendSimple channel "foobar") (void (takeMVar msgSentMVar) >> dispose channel)
    runMultiplexer MultiplexerSideA (liftIO . testAction) connection


withEchoServer :: (Channel -> QuasarIO ()) -> IO ()
withEchoServer fn = rm $ bracket setup closePair (\(channel, _) -> fn channel)
  where
    setup :: QuasarIO (Channel, Channel)
    setup = do
      (mainSocket, echoSocket) <- newConnectionPair
      mainChannel <- newMultiplexer MultiplexerSideA mainSocket
      echoChannel <- newMultiplexer MultiplexerSideB echoSocket
      configureEchoHandler echoChannel
      pure (mainChannel, echoChannel)
    closePair :: (Channel, Channel) -> QuasarIO ()
    closePair (x, y) = dispose x >> dispose y
    configureEchoHandler :: MonadIO m => Channel -> m ()
    configureEchoHandler channel = channelSetHandler channel (echoHandler channel)
    echoHandler :: Channel -> ReceivedMessageResources -> BSL.ByteString -> QuasarIO ()
    echoHandler channel resources msg = do
      mapM_ configureEchoHandler resources.createdChannels
      channelSendSimple channel msg
