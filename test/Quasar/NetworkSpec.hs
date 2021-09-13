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
import Control.Concurrent.STM
import Quasar.Prelude
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Network
import Quasar.Network.Runtime (withStandaloneClient)
import Quasar.Network.TH (makeRpc)
import Quasar.Observable
import Quasar.ResourceManager
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic


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

$(makeRpc $ rpcApi "StreamExample" $ do
    rpcFunction "createMultiplyStream" $ do
      addStream "stream" [t|(Int, Int)|] [t|Int|]

    rpcFunction "createStreams" $ do
      addStream "stream1" [t|Bool|] [t|Bool|]
      addStream "stream2" [t|Int|] [t|Int|]
  )

$(makeRpc $ rpcApi "ObservableExample" $ do
    rpcObservable "intObservable" [t|Int|]
  )

exampleProtocolImpl :: ExampleProtocolImpl
exampleProtocolImpl = ExampleProtocolImpl {
  multiArgsImpl = \one two three -> pure $ pure (one + two, not three),
  noArgsImpl = pure $ pure 42,
  noResponseImpl = \_foo -> pure (),
  noNothingImpl = pure ()
}

streamExampleProtocolImpl :: StreamExampleProtocolImpl
streamExampleProtocolImpl = StreamExampleProtocolImpl {
  createMultiplyStreamImpl,
  createStreamsImpl
}
  where
    createMultiplyStreamImpl :: MonadIO m => Stream Int (Int, Int) -> m ()
    createMultiplyStreamImpl stream = streamSetHandler stream $ \(x, y) -> streamSend stream (x * y)
    createStreamsImpl :: MonadIO m => Stream Bool Bool -> Stream Int Int -> m ()
    createStreamsImpl stream1 stream2 = do
      streamSetHandler stream1 $ streamSend stream1
      streamSetHandler stream2 $ streamSend stream2


spec :: Spec
spec = parallel $ do
  describe "Example" $ do
    it "works" $ do
      withStandaloneClient @ExampleProtocol exampleProtocolImpl $ \client -> do
        (await =<< fixedHandler42 client 5) `shouldReturn` False
        (await =<< fixedHandler42 client 42) `shouldReturn` True
        (await =<< fixedHandlerInc client 41) `shouldReturn` 42
        (await =<< multiArgs client 10 3 False) `shouldReturn` (13, True)
        (await =<< noArgs client) `shouldReturn` 42
        noResponse client 1337
        noNothing client

  describe "StreamExample" $ do
    it "can open and close a stream" $ do
      withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        await =<< streamClose =<< createMultiplyStream client

    it "can open multiple streams in a single rpc call" $ do
      withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        (stream1, stream2) <- createStreams client
        await =<< liftA2 (<>) (streamClose stream1) (streamClose stream2)

    aroundAll (\x -> withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        resultMVar <- liftIO newEmptyMVar
        stream <- createMultiplyStream client
        streamSetHandler stream $ putMVar resultMVar
        liftIO $ x (resultMVar, stream)
      ) $ it "can send data over the stream" $ \(resultMVar, stream) -> property $ \(x, y) -> monadicIO $ do
        liftIO $ streamSend stream (x, y)
        liftIO $ takeMVar resultMVar `shouldReturn` x * y

  describe "ObservableExample" $ do
    it "can retrieve values" $ do
      var <- newObservableVar 42
      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
        observable <- intObservable client
        retrieveIO observable `shouldReturn` 42
        setObservableVar var 13
        retrieveIO observable `shouldReturn` 13

    it "receives the current value when calling observe" $ do
      var <- newObservableVar 41

      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do

        resultVar <- newTVarIO ObservableLoading
        observable <- intObservable client

        -- Change the value before calling `observe`
        setObservableVar var 42

        withResourceManagerM $ runUnlimitedAsync do
          observe observable $ \msg -> liftIO $ atomically $ writeTVar resultVar msg

          liftIO $ join $ atomically $ readTVar resultVar >>=
            \case
              ObservableUpdate x -> pure $ x `shouldBe` 42
              ObservableLoading -> retry
              ObservableNotAvailable ex -> pure $ throwIO ex

    it "receives continuous updates when observing" $ do
      var <- newObservableVar 42
      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
        resultVar <- newTVarIO ObservableLoading
        observable <- intObservable client
        withResourceManagerM $ runUnlimitedAsync do
          observe observable $ \msg -> liftIO $ atomically $ writeTVar resultVar msg

          let latestShouldBe = \expected -> liftIO $ join $ atomically $ readTVar resultVar >>=
                \case
                  -- Send and receive are running asynchronously, so this retries until the expected value is received.
                  -- Blocks forever if the wrong or no value is received.
                  ObservableUpdate x -> if (x == expected) then pure (pure ()) else retry
                  ObservableLoading -> retry
                  ObservableNotAvailable ex -> pure $ throwIO ex

          latestShouldBe 42
          setObservableVar var 13
          latestShouldBe 13
          setObservableVar var (-1)
          latestShouldBe (-1)
          setObservableVar var 42
          latestShouldBe 42

    it "receives no further updates after unsubscribing" $ do
      var <- newObservableVar 42
      withStandaloneClient @ObservableExampleProtocol (ObservableExampleProtocolImpl (toObservable var)) $ \client -> do
        resultVar <- newTVarIO ObservableLoading
        observable <- intObservable client
        withResourceManagerM $ runUnlimitedAsync do
          disposable <- captureDisposable $ observe observable $ \msg -> liftIO $ atomically $ writeTVar resultVar msg

          let latestShouldBe = \expected -> liftIO $ join $ atomically $ readTVar resultVar >>=
                \case
                  -- Send and receive are running asynchronously, so this retries until the expected value is received.
                  -- Blocks forever if the wrong or no value is received.
                  ObservableUpdate x -> if (x < 0)
                    then pure (fail "received a message after unsubscribing")
                    else if (x == expected) then pure (pure ()) else retry
                  ObservableLoading -> retry
                  ObservableNotAvailable ex -> pure $ throwIO ex

          latestShouldBe 42
          setObservableVar var 13
          latestShouldBe 13
          setObservableVar var 42
          latestShouldBe 42

          disposeAndAwait disposable

          setObservableVar var (-1)
          liftIO $ threadDelay 10000

          latestShouldBe 42
