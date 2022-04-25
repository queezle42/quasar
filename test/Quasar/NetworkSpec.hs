-- For rpc:
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE EmptyDataDeriving #-}

-- Print generated rpc code during build
{-# OPTIONS_GHC -ddump-splices #-}

module Quasar.NetworkSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Quasar
import Quasar.Network
import Quasar.Network.Runtime (withStandaloneClient)
import Quasar.Network.TH (makeRpc)
import Quasar.Network.Multiplexer
import Quasar.Prelude
import Test.Hspec.Core.Spec
import Test.Hspec.Expectations.Lifted
import Test.Hspec qualified as Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions (stderrLogger LogLevelWarning)

shouldThrow :: (HasCallStack, Exception e, MonadQuasar m, MonadIO m) => QuasarIO a -> Hspec.Selector e -> m ()
shouldThrow action expected = do
  quasar <- askQuasar
  liftIO $ runQuasarIO quasar action `Hspec.shouldThrow` expected


$(makeRpc $ rpcApi "Example" $ do
    rpcFunction "fixedHandler42" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Bool|]
      setFixedHandler [| pure . pure . (== 42) |]

    rpcFunction "fixedHandlerInc" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Int|]
      setFixedHandler [| pure . pure . (+ 1) |]

    rpcFunction "multiArgs" $ do
      addArgument "one" [t|Int|]
      addArgument "two" [t|Int|]
      addArgument "three" [t|Bool|]
      addResult "result" [t|Int|]
      addResult "result2" [t|Bool|]

    rpcFunction "noArgs" $ do
      addResult "result" [t|Int|]

    rpcFunction "noResponse" $ do
      addArgument "arg" [t|Int|]

    rpcFunction "noNothing" $ pure ()
  )

$(makeRpc $ rpcApi "ChannelExample" $ do
    rpcFunction "exampleCreateMultiplyChannel" $ do
      addChannel "channel" [t|(Int, Int)|] [t|Int|]

    rpcFunction "exampleCreateChannels" $ do
      addChannel "channel1" [t|Bool|] [t|Bool|]
      addChannel "channel2" [t|Int|] [t|Int|]
  )

-- $(makeRpc $ rpcApi "ObservableExample" $ do
--     rpcObservable "intObservable" [t|Int|]
--   )

exampleProtocolImpl :: ExampleProtocolImpl
exampleProtocolImpl = ExampleProtocolImpl {
  multiArgsImpl = \one two three -> pure $ pure (one + two, not three),
  noArgsImpl = pure $ pure 42,
  noResponseImpl = \_foo -> pure (),
  noNothingImpl = pure ()
}

channelExampleProtocolImpl :: ChannelExampleProtocolImpl
channelExampleProtocolImpl = ChannelExampleProtocolImpl {
  exampleCreateMultiplyChannelImpl,
  exampleCreateChannelsImpl
}
  where
    exampleCreateMultiplyChannelImpl :: MonadIO m => Channel Int (Int, Int) -> m ()
    exampleCreateMultiplyChannelImpl channel = channelSetHandler channel $ \(x, y) -> channelSend channel (x * y)
    exampleCreateChannelsImpl :: MonadIO m => Channel Bool Bool -> Channel Int Int -> m ()
    exampleCreateChannelsImpl channel1 channel2 = do
      channelSetHandler channel1 $ channelSend channel1
      channelSetHandler channel2 $ channelSend channel2


spec :: Spec
spec = parallel $ do
  describe "Example" $ do
    it "works" $ rm do
      withStandaloneClient @ExampleProtocol exampleProtocolImpl $ \client -> do
        (await =<< fixedHandler42 client 5) `shouldReturn` False
        (await =<< fixedHandler42 client 42) `shouldReturn` True
        (await =<< fixedHandlerInc client 41) `shouldReturn` 42
        (await =<< multiArgs client 10 3 False) `shouldReturn` (13, True)
        (await =<< noArgs client) `shouldReturn` 42
        noResponse client 1337
        noNothing client

  describe "ChannelExample" $ do
    it "can open and close a channel" $ rm do
      withStandaloneClient @ChannelExampleProtocol channelExampleProtocolImpl $ \client -> do
        dispose =<< exampleCreateMultiplyChannel client

    it "can open multiple channels in a single rpc call" $ rm do
      withStandaloneClient @ChannelExampleProtocol channelExampleProtocolImpl $ \client -> do
        (channel1, channel2) <- exampleCreateChannels client
        dispose channel1
        dispose channel2

    Hspec.aroundAll (\x -> rm $ withStandaloneClient @ChannelExampleProtocol channelExampleProtocolImpl $ \client -> do
        resultMVar <- liftIO newEmptyMVar
        channel <- exampleCreateMultiplyChannel client
        channelSetHandler channel $ liftIO . putMVar resultMVar
        liftIO $ x (resultMVar, channel)
      ) $ it "can send data over the channel" $ \(resultMVar, channel) -> property $ \(x, y) -> monadicIO $ do
        liftIO $ channelSend channel (x, y)
        liftIO $ takeMVar resultMVar `shouldReturn` x * y

--  describe "ObservableExample" $ do
--    it "can retrieve values" $ rm do
--      var <- newObservableVarIO 42
--      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
--        observable <- intObservable client
--        retrieve observable `shouldReturn` 42
--        atomically $ setObservableVar var 13
--        retrieve observable `shouldReturn` 13
--
--    it "receives the current value when calling observe" $ rm do
--      var <- newObservableVarIO 41
--
--      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
--
--        resultVar <- newTVarIO ObservableLoading
--        observable <- intObservable client
--
--        -- Change the value before calling `observe`
--        atomically $ setObservableVar var 42
--
--        observeIO_ observable $ \msg -> writeTVar resultVar msg
--
--        liftIO $ join $ atomically $ readTVar resultVar >>=
--          \case
--            ObservableValue x -> pure $ x `shouldBe` 42
--            ObservableLoading -> retry
--            ObservableNotAvailable ex -> pure $ throwIO ex
--
--    it "receives continuous updates when observing" $ rm do
--      var <- newObservableVarIO 42
--      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
--        resultVar <- newTVarIO ObservableLoading
--        observable <- intObservable client
--
--        observeIO_ observable $ \msg -> writeTVar resultVar msg
--
--        let latestShouldBe = \expected -> liftIO $ join $ atomically $ readTVar resultVar >>=
--              \case
--                -- Send and receive are running asynchronously, so this retries until the expected value is received.
--                -- Blocks forever if the wrong or no value is received.
--                ObservableValue x -> if x == expected then pure (pure ()) else retry
--                ObservableLoading -> retry
--                ObservableNotAvailable ex -> pure $ throwIO ex
--
--        latestShouldBe 42
--        atomically $ setObservableVar var 13
--        latestShouldBe 13
--        atomically $ setObservableVar var (-1)
--        latestShouldBe (-1)
--        atomically $ setObservableVar var 42
--        latestShouldBe 42
--
--    it "receives no further updates after unsubscribing" $ rm do
--      var <- newObservableVarIO 42
--      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
--        resultVar <- newTVarIO ObservableLoading
--        observable <- intObservable client
--
--        disposer <- observeIO observable $ \msg -> writeTVar resultVar msg
--
--        let latestShouldBe = \expected -> liftIO $ join $ atomically $ readTVar resultVar >>=
--              \case
--                -- Send and receive are running asynchronously, so this retries until the expected value is received.
--                -- Blocks forever if the wrong or no value is received.
--                ObservableValue x -> if x < 0
--                  then pure (fail "received a message after unsubscribing")
--                  else if x == expected then pure (pure ()) else retry
--                ObservableLoading -> retry
--                ObservableNotAvailable ex -> pure $ throwIO ex
--
--        latestShouldBe 42
--        atomically $ setObservableVar var 13
--        latestShouldBe 13
--        atomically $ setObservableVar var 42
--        latestShouldBe 42
--
--        dispose disposer
--
--        atomically $ setObservableVar var (-1)
--        liftIO $ threadDelay 10000
--
--        latestShouldBe 42
