module Quasar.Network.MultiplexerSpec (spec) where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar
import Control.Monad.Catch
import Data.ByteString.Lazy qualified as BSL
import Quasar
import Quasar.Network.Connection
import Quasar.Network.Multiplexer
import Quasar.Prelude
import Test.Hspec.Core.Spec
import Test.Hspec.Expectations.Lifted

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions

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
    var <- newPromiseIO
    (x, y) <- newConnectionPair
    void $ newMultiplexer MultiplexerSideB y
    runMultiplexer
      do MultiplexerSideA
      do
        \channel -> do
          runQuasarIO channel.quasar $ registerDisposeTransactionIO_ (fulfillPromise var ())
          dispose channel
      do x
    peekFutureIO (toFuture var) `shouldReturn` Just ()

  it "can send and receive simple messages" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      rawChannelSetSimpleByteStringHandler channel ((liftIO . putMVar recvMVar) :: BSL.ByteString -> QuasarIO ())
      sendSimpleRawChannelMessage channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"
      sendSimpleRawChannelMessage channel "test"
      liftIO $ takeMVar recvMVar `shouldReturn` "test"

    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can create sub-channels" $ do
    recvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      rawChannelSetByteStringHandler channel ((\_ -> liftIO . putMVar recvMVar) :: ReceivedMessageResources -> BSL.ByteString -> QuasarIO ())
      SentMessageResources{createdChannels=[_]} <- sendRawChannelMessage channel (channelMessage "create a channel"){createChannels=1}
      liftIO $ takeMVar recvMVar `shouldReturn` "create a channel"
      SentMessageResources{createdChannels=[_, _, _]} <- sendRawChannelMessage channel (channelMessage "create more channels"){createChannels=3}
      liftIO $ takeMVar recvMVar `shouldReturn` "create more channels"
    tryReadMVar recvMVar `shouldReturn` Nothing

  it "can send messages on sub-channels" $ do
    recvMVar <- newEmptyMVar
    c1RecvMVar <- newEmptyMVar
    c2RecvMVar <- newEmptyMVar
    c3RecvMVar <- newEmptyMVar
    withEchoServer $ \channel -> do
      rawChannelSetSimpleByteStringHandler channel $ (liftIO . putMVar recvMVar :: BSL.ByteString -> QuasarIO ())
      sendSimpleRawChannelMessage channel "foobar"
      liftIO $ takeMVar recvMVar `shouldReturn` "foobar"

      SentMessageResources{createdChannels=[c1, c2]} <- sendRawChannelMessage channel (channelMessage "create channels"){createChannels=2}
      liftIO $ takeMVar recvMVar `shouldReturn` "create channels"
      rawChannelSetSimpleByteStringHandler c1 (liftIO . putMVar c1RecvMVar :: BSL.ByteString -> QuasarIO ())
      rawChannelSetSimpleByteStringHandler c2 (liftIO . putMVar c2RecvMVar :: BSL.ByteString -> QuasarIO ())

      sendSimpleRawChannelMessage c1 "test"
      liftIO $ takeMVar c1RecvMVar `shouldReturn` "test"
      sendSimpleRawChannelMessage c2 "test2"
      liftIO $ takeMVar c2RecvMVar `shouldReturn` "test2"
      sendSimpleRawChannelMessage c2 "test3"
      liftIO $ takeMVar c2RecvMVar `shouldReturn` "test3"
      sendSimpleRawChannelMessage c1 "test4"
      liftIO $ takeMVar c1RecvMVar `shouldReturn` "test4"

      SentMessageResources{createdChannels=[c3]} <- sendRawChannelMessage channel (channelMessage "create another channel"){createChannels=1}
      liftIO $ takeMVar recvMVar `shouldReturn` "create another channel"
      rawChannelSetSimpleByteStringHandler c3 (liftIO . putMVar c3RecvMVar :: BSL.ByteString -> QuasarIO ())

      sendSimpleRawChannelMessage c3 "test5"
      liftIO $ takeMVar c3RecvMVar `shouldReturn` "test5"
      sendSimpleRawChannelMessage c1 "test6"
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
      testAction :: RawChannel -> IO ()
      testAction channel = concurrently_ (sendSimpleRawChannelMessage channel "foobar") (void (takeMVar msgSentMVar) >> dispose channel)
    runMultiplexer MultiplexerSideA (liftIO . testAction) connection


withEchoServer :: (RawChannel -> QuasarIO ()) -> IO ()
withEchoServer fn = rm $ bracket setup closePair (\(channel, _) -> fn channel)
  where
    setup :: QuasarIO (RawChannel, RawChannel)
    setup = do
      (mainSocket, echoSocket) <- newConnectionPair
      mainChannel <- newMultiplexer MultiplexerSideA mainSocket
      echoChannel <- newMultiplexer MultiplexerSideB echoSocket
      (handler, ()) <- configureEchoHandler echoChannel
      atomically $ rawChannelSetHandler echoChannel handler
      pure (mainChannel, echoChannel)
    closePair :: (RawChannel, RawChannel) -> QuasarIO ()
    closePair (x, y) = dispose x >> dispose y
    configureEchoHandler :: Monad m => RawChannel -> m (RawChannelHandler, ())
    configureEchoHandler channel = pure (byteStringHandler (echoHandler channel), ())
    echoHandler :: RawChannel -> ReceivedMessageResources -> BSL.ByteString -> QuasarIO ()
    echoHandler channel resources msg = do
      atomicallyC do
        replicateM_ resources.numCreatedChannels do
          initializeReceivedChannel resources configureEchoHandler
      sendSimpleRawChannelMessage channel msg
