{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -ddump-splices #-}

module Network.RpcSpec where

import Prelude
import Network.Rpc
import Test.Hspec

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

exampleProtocolImpl :: ExampleProtocolImpl
exampleProtocolImpl = ExampleProtocolImpl {
  multiArgsImpl = \one two three -> pure (one + two, not three),
  noArgsImpl = pure 42,
  noResponseImpl = \_foo -> pure (),
  noNothingImpl = pure ()
}

spec :: Spec
spec = describe "DummyClient" $ parallel $ do
  it "works" $ do
    withDummyClientServer @ExampleProtocol exampleProtocolImpl $ \client -> do
      fixedHandler42 client 5 `shouldReturn` False
      fixedHandler42 client 42 `shouldReturn` True
      fixedHandlerInc client 41 `shouldReturn` 42
      multiArgs client 10 3 False `shouldReturn` (13, True)
      noResponse client 1337
      noNothing client
