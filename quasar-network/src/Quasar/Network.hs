module Quasar.Network (
  -- * Types
  NetworkObject(..),

  -- * Client
  Client(..),
  withClientTCP,
  withClientUnix,
  withClient,

  -- * Server
  Server,
  Listener(..),
  runServer,
  listenTCP,
  listenUnix,
  listenOnBoundSocket,

  -- ** Server configuration
  ServerConfig(..),
  simpleServerConfig,

  -- * NetworkObject implementation strategies
  Binary,
  Generic,
  NetworkReference,
  NetworkRootReference,
) where

import Data.Binary (Binary)
import GHC.Generics (Generic)
import Quasar.Network.Client
import Quasar.Network.Runtime
import Quasar.Network.Server
