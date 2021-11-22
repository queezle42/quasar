module Quasar.Network.MultiplexerSpec (spec) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar
import Control.Monad.Catch
import Control.Monad.Reader (ReaderT)
import Data.ByteString.Lazy qualified as BSL
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network.Multiplexer
import Quasar.Network.Connection
import Quasar.Prelude
import Quasar.ResourceManager
import Test.Hspec.Core.Spec
import Test.Hspec.Expectations.Lifted
import Test.Hspec qualified as Hspec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: ResourceManagerIO a -> IO a
rm = withRootResourceManager

shouldThrow :: (HasCallStack, Exception e, MonadResourceManager m) => (ReaderT ResourceManager IO a) -> Hspec.Selector e -> m ()
shouldThrow action expected = do
  resourceManager <- askResourceManager
  liftIO $ (onResourceManager resourceManager action) `Hspec.shouldThrow` expected

spec :: Spec
spec = describe "runMultiplexer" $ parallel $ do
  fit "can be closed from the channelSetupHook" do
    (x, y) <- newConnectionPair
    concurrently_
      do rm (runMultiplexer MultiplexerSideA dispose x)
      do rm (runMultiplexer MultiplexerSideB dispose y)

  fit "closes when the remote is closed" do
    (x, y) <- newConnectionPair
    concurrently_
      do rm (runMultiplexer MultiplexerSideA (\rootChannel -> await (isDisposed rootChannel)) x)
      do rm (runMultiplexer MultiplexerSideB dispose y)

  fit "can dispose a resource" $ rm do
    var <- newAsyncVar
    (x, y) <- newConnectionPair
    void $ newMultiplexer MultiplexerSideB y
    runMultiplexer
      do MultiplexerSideA
      do
        \channel -> do
          attachDisposeAction_ channel.resourceManager (putAsyncVar_ var ())
          dispose channel
      do x
    peekAwaitable var `shouldReturn` Just ()

  fit "can send and receive simple messages" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetSimpleHandler channel ((liftIO . putMVar recvMVar) :: BSL.ByteString -> ResourceManagerIO ())
      channelSendSimple channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"
      channelSendSimple channel "test"
      liftIO $ takeMVar recvMVar `shouldReturn` "test"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can create sub-channels" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel ((\_ -> liftIO . putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> ResourceManagerIO ())
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
      channelSetSimpleHandler channel $ (liftIO . putMVar recvMVar :: BSL.ByteString -> ResourceManagerIO ())
      channelSendSimple channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"

      SentMessageResources{createdChannels=[c1, c2]} <- channelSend_ channel defaultMessageConfiguration{createChannels=2}  "create channels"
      liftIO $ takeMVar recvMVar `shouldReturn` "create channels"
      channelSetSimpleHandler c1 (liftIO . putMVar c1RecvMVar :: BSL.ByteString -> ResourceManagerIO ())
      channelSetSimpleHandler c2 (liftIO . putMVar c2RecvMVar :: BSL.ByteString -> ResourceManagerIO ())

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
      channelSetSimpleHandler c3 (liftIO . putMVar c3RecvMVar :: BSL.ByteString -> ResourceManagerIO ())

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
        send = const (putMVar msgSentMVar () >> sleepForever),
        receive = sleepForever,
        close = pure ()
      }
      testAction :: Channel -> IO ()
      testAction channel = concurrently_ (channelSendSimple channel "foobar") (void (takeMVar msgSentMVar) >> dispose channel)
    runMultiplexer MultiplexerSideA (liftIO . testAction) connection


withEchoServer :: (Channel -> ResourceManagerIO ()) -> IO ()
withEchoServer fn = rm $ bracket setup closePair (\(channel, _) -> fn channel)
  where
    setup :: ResourceManagerIO (Channel, Channel)
    setup = do
      (mainSocket, echoSocket) <- newConnectionPair
      mainChannel <- newMultiplexer MultiplexerSideA mainSocket
      echoChannel <- newMultiplexer MultiplexerSideB echoSocket
      configureEchoHandler echoChannel
      pure (mainChannel, echoChannel)
    closePair :: MonadResourceManager m => (Channel, Channel) -> m ()
    closePair (x, y) = dispose x >> dispose y
    configureEchoHandler :: MonadIO m => Channel -> m ()
    configureEchoHandler channel = channelSetHandler channel (echoHandler channel)
    echoHandler :: Channel -> ReceivedMessageResources -> BSL.ByteString -> ResourceManagerIO ()
    echoHandler channel resources msg = do
      mapM_ configureEchoHandler resources.createdChannels
      channelSendSimple channel msg
