module Network.Rpc.MultiplexerSpec where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar
import Control.Exception (bracket, mask_)
import Control.Monad (forever, void)
import qualified Data.ByteString.Lazy as BSL
import Prelude
import Network.Rpc.Multiplexer
import Network.Rpc.Connection
import Test.Hspec

spec :: Spec
spec = describe "runMultiplexerProtocol" $ parallel $ do
  it "can be closed from the channelSetupHook" $ do
    (x, _) <- newDummySocketPair
    runMultiplexer MultiplexerSideA channelClose x

  it "fails when run in masked state" $ do
    (x, _) <- newDummySocketPair
    mask_ $ runMultiplexer MultiplexerSideA channelClose x `shouldThrow` anyException

  it "closes when the remote is closed" $ do
    (x, y) <- newDummySocketPair
    concurrently_
      (runMultiplexer MultiplexerSideA (const (pure ())) x)
      (runMultiplexer MultiplexerSideB channelClose y)

  it "can send and receive simple messages" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel ((\_ -> putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())
      channelSendSimple channel "foobar"
      takeMVar recvMVar `shouldReturn` "foobar"
      channelSendSimple channel "test"
      takeMVar recvMVar `shouldReturn` "test"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can create sub-channels" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel ((\_ -> putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())
      SentMessageResources{createdChannels=[_]} <- channelSend_ channel [CreateChannelHeader] "create a channel"
      takeMVar recvMVar `shouldReturn` "create a channel"
      SentMessageResources{createdChannels=[_, _, _]} <- channelSend_ channel [CreateChannelHeader, CreateChannelHeader, CreateChannelHeader] "create more channels"
      takeMVar recvMVar `shouldReturn` "create more channels"
    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can send messages on sub-channels" $ do
    recvMVar <- newEmptyMVar
    c1RecvMVar <- newEmptyMVar
    c2RecvMVar <- newEmptyMVar
    c3RecvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel $ ((\_ -> putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())
      channelSendSimple channel "foobar"
      takeMVar recvMVar `shouldReturn` "foobar"

      SentMessageResources{createdChannels=[c1, c2]} <- channelSend_ channel [CreateChannelHeader, CreateChannelHeader] "create channels"
      takeMVar recvMVar `shouldReturn` "create channels"
      channelSetHandler c1 ((\_ -> putMVar c1RecvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())
      channelSetHandler c2 ((\_ -> putMVar c2RecvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())

      channelSendSimple c1 "test"
      takeMVar c1RecvMVar `shouldReturn` "test"
      channelSendSimple c2 "test2"
      takeMVar c2RecvMVar `shouldReturn` "test2"
      channelSendSimple c2 "test3"
      takeMVar c2RecvMVar `shouldReturn` "test3"
      channelSendSimple c1 "test4"
      takeMVar c1RecvMVar `shouldReturn` "test4"

      SentMessageResources{createdChannels=[c3]} <- channelSend_ channel [CreateChannelHeader] "create another channel"
      takeMVar recvMVar `shouldReturn` "create another channel"
      channelSetHandler c3 ((\_ -> putMVar c3RecvMVar) :: ReceivedMessageResources -> BSL.ByteString -> IO ())

      channelSendSimple c3 "test5"
      takeMVar c3RecvMVar `shouldReturn` "test5"
      channelSendSimple c1 "test6"
      takeMVar c1RecvMVar `shouldReturn` "test6"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can terminate a connection when the connection backend hangs" $ do
    msgSentMVar <- newEmptyMVar
    let
      sleepForever = forever (threadDelay 1000000000)
      connection = Connection {
        send = const (putMVar msgSentMVar () >> sleepForever),
        receive = sleepForever,
        close = pure ()
      }
      testAction :: Channel -> IO ()
      testAction channel = concurrently_ (channelSendSimple channel "foobar") (void (takeMVar msgSentMVar) >> channelClose channel)
    runMultiplexer MultiplexerSideA testAction connection


withEchoServer :: (Channel -> IO a) -> IO a
withEchoServer fn = bracket setup close (\(channel, _) -> fn channel)
  where
    setup :: IO (Channel, Channel)
    setup = do
      (x, y) <- newDummySocketPair
      mainChannel <- newMultiplexer MultiplexerSideA x
      echoChannel <- newMultiplexer MultiplexerSideB y
      configureEchoHandler echoChannel
      pure (mainChannel, echoChannel)
    close :: (Channel, Channel) -> IO ()
    close (x, y) = channelClose x >> channelClose y
    configureEchoHandler :: Channel -> IO ()
    configureEchoHandler channel = channelSetHandler channel (echoHandler channel)
    echoHandler :: Channel -> ReceivedMessageResources -> BSL.ByteString -> IO ()
    echoHandler channel resources msg = do
      mapM_ configureEchoHandler resources.createdChannels
      channelSendSimple channel msg
