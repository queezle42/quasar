module Quasar.Network (
  -- * Rpc api definition
  RpcApi,
  RpcFunction,
  RpcArgument,
  RpcResult,
  RpcStream,
  rpcApi,
  rpcFunction,
  addArgument,
  addResult,
  addStream,
  setFixedHandler,
  rpcObservable,

  -- * Runtime

  -- ** Client
  Client,
  clientSend,
  clientReportProtocolError,

  withClientTCP,
  withClientUnix,
  withClient,

  -- ** Server
  Server,
  Listener(..),
  runServer,
  withLocalClient,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,

  -- ** Stream
  Stream,
  streamSend,
  streamSetHandler,
) where

import Quasar.Network.TH
import Quasar.Network.Runtime
