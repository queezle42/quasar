module Network.Rpc.MultiplexerSpec where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar
import Control.Exception (bracket, mask_)
import Prelude
import Network.Rpc.Multiplexer
import Network.Rpc.Connection
import Test.Hspec

spec :: Spec
spec = describe "runMultiplexerProtocol" $ parallel $ do
  it "can be closed from the channelSetupHook" $ do
    (x, _) <- newDummySocketPair
    runMultiplexer channelClose x

  it "fails when run in masked state" $ do
    (x, _) <- newDummySocketPair
    mask_ $ runMultiplexer channelClose x `shouldThrow` anyException

  it "closes when the remote is closed" $ do
    (x, y) <- newDummySocketPair
    concurrently_
      (runMultiplexer (const (pure ())) x)
      (runMultiplexer channelClose y)

  it "it can send and receive simple messages" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      channelSetHandler channel $ simpleMessageHandler $ \_ _ -> putMVar recvMVar
      channelSend_ channel [] "foobar"
      takeMVar recvMVar `shouldReturn` "foobar"
      channelSend_ channel [] "test"
      takeMVar recvMVar `shouldReturn` "test"

    tryReadMVar recvMVar `shouldReturn` Nothing


withEchoServer :: (Channel -> IO a) -> IO a
withEchoServer fn = bracket setup close (\(channel, _) -> fn channel)
  where
    setup :: IO (Channel, Channel)
    setup = do
      (x, y) <- newDummySocketPair
      echoChannel <- newMultiplexer y
      configureEchoHandler echoChannel
      mainChannel <- newMultiplexer x
      pure (mainChannel, echoChannel)
    close :: (Channel, Channel) -> IO ()
    close (x, y) = channelClose x >> channelClose y
    configureEchoHandler :: Channel -> IO ()
    configureEchoHandler channel = channelSetHandler channel (echoHandler channel)
    echoHandler :: Channel -> ChannelMessageHandler
    echoHandler channel = simpleMessageHandler $ \_msgId headers msg -> do
      mapM_ echoHeaderHandler headers
      channelSend_ channel [] msg
    echoHeaderHandler :: MessageHeaderResult -> IO ()
    echoHeaderHandler (CreateChannelHeaderResult channel) = configureEchoHandler channel
