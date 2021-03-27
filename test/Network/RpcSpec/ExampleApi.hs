module Network.RpcSpec.ExampleApi where

import Prelude
import Network.Rpc

data Something = Something

exampleApi :: RpcApi
exampleApi = rpcApi "Example" [
    rpcFunction "fixedHandler42" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Bool|]
      setFixedHandler [| return . (== 42) |],
    rpcFunction "fixedHandlerInc" $ do
      addArgument "arg" [t|Int|]
      addResult "result" [t|Int|]
      setFixedHandler [| return . (+ 1) |],
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
    rpcFunction "noNothing" $ return ()
  ]
