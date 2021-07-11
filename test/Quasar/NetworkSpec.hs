-- For rpc:
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE EmptyDataDeriving #-}

-- Print generated rpc code during build
{-# OPTIONS_GHC -ddump-splices #-}

module Quasar.NetworkSpec where

import Control.Concurrent.MVar
import Control.Monad.IO.Class (liftIO)
import Prelude
import Quasar.Network
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic

$(makeRpc $ rpcApi "Example" [
    rpcFunction "fixedHandler42" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Bool|]
      setFixedHandler [| pure . (== 42) |],
    rpcFunction "fixedHandlerInc" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Int|]
      setFixedHandler [| pure . (+ 1) |],
    rpcFunction "multiArgs" $ do
      addArgument "one" [t|Int|]
      addArgument "two" [t|Int|]
      addArgument "three" [t|Bool|]
      addResult "result" [t|Int|]
      addResult "result2" [t|Bool|],
    rpcFunction "noArgs" $ do
      addResult "result" [t|Int|],
    rpcFunction "noResponse" $ do
      addArgument "arg" [t|Int|],
    rpcFunction "noNothing" $ pure ()
    ]
 )

$(makeRpc $ rpcApi "StreamExample" [
    rpcFunction "createMultiplyStream" $ do
      addStream "stream" [t|(Int, Int)|] [t|Int|]
    ,
    rpcFunction "createStreams" $ do
      addStream "stream1" [t|Bool|] [t|Bool|]
      addStream "stream2" [t|Int|] [t|Int|]
    ]
 )

exampleProtocolImpl :: ExampleProtocolImpl
exampleProtocolImpl = ExampleProtocolImpl {
  multiArgsImpl = \one two three -> pure (one + two, not three),
  noArgsImpl = pure 42,
  noResponseImpl = \_foo -> pure (),
  noNothingImpl = pure ()
}

streamExampleProtocolImpl :: StreamExampleProtocolImpl
streamExampleProtocolImpl = StreamExampleProtocolImpl {
  createMultiplyStreamImpl,
  createStreamsImpl
}
  where
    createMultiplyStreamImpl :: Stream Int (Int, Int) -> IO ()
    createMultiplyStreamImpl stream = streamSetHandler stream $ \(x, y) -> streamSend stream (x * y)
    createStreamsImpl :: Stream Bool Bool -> Stream Int Int -> IO ()
    createStreamsImpl stream1 stream2 = do
      streamSetHandler stream1 $ streamSend stream1
      streamSetHandler stream2 $ streamSend stream2

spec :: Spec
spec = parallel $ do
  describe "Example" $ do
    it "works" $ do
      withStandaloneClient @ExampleProtocol exampleProtocolImpl $ \client -> do
        fixedHandler42 client 5 `shouldReturn` False
        fixedHandler42 client 42 `shouldReturn` True
        fixedHandlerInc client 41 `shouldReturn` 42
        multiArgs client 10 3 False `shouldReturn` (13, True)
        noResponse client 1337
        noNothing client

  describe "StreamExample" $ do
    it "can open and close a stream" $ do
      withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        streamClose =<< createMultiplyStream client

    it "can open multiple streams in a single rpc call" $ do
      withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        (stream1, stream2) <- createStreams client
        streamClose stream1
        streamClose stream2

    aroundAll (\x -> withStandaloneClient @StreamExampleProtocol streamExampleProtocolImpl $ \client -> do
        resultMVar <- newEmptyMVar
        stream <- createMultiplyStream client
        streamSetHandler stream $ putMVar resultMVar
        x (resultMVar, stream)
      ) $ it "can send data over the stream" $ \(resultMVar, stream) -> property $ \(x, y) -> monadicIO $ do
        liftIO $ streamSend stream (x, y)
        liftIO $ takeMVar resultMVar `shouldReturn` x * y

