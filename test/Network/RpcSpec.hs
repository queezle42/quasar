{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -ddump-splices #-}

module Network.RpcSpec where

import Prelude
import Network.Rpc
import Test.Hspec
import Network.RpcSpec.ExampleApi


$(makeProtocol exampleApi)
$(makeClient exampleApi)
$(makeServer exampleApi)

exampleProtocolImpl :: ExampleProtocolImpl
exampleProtocolImpl = ExampleProtocolImpl {
  multiArgsImpl = \one two three -> return (one + two, not three),
  noArgsImpl = return 42,
  noResponseImpl = \_foo -> return (),
  noNothingImpl = return ()
}

spec :: Spec
spec = describe "DummyClient" $ parallel $ do
  it "works" $ do
    let client = DummyClient @ExampleProtocol exampleProtocolImpl
    fixedHandler42 client 5 `shouldReturn` False
    fixedHandler42 client 42 `shouldReturn` True
    fixedHandlerInc client 41 `shouldReturn` 42
    multiArgs client 10 3 False `shouldReturn` (13, True)
    noResponse client 1337
    noNothing client
