module Quasar.Network.Exception (
  PackedException(..), packException, unpackException
) where

import Control.Exception
import Data.Binary (Binary(..))
import Quasar.Prelude

data PackedException = PackedAnyException AnyException
  deriving stock (Show, Eq, Generic)
  deriving anyclass Binary

data AnyException = AnyException String
  deriving stock (Show, Eq, Generic)
  deriving anyclass (Binary, Exception)


packException :: Exception e => e -> PackedException
packException ex = PackedAnyException $ AnyException $ displayException ex

unpackException :: PackedException -> SomeException
unpackException (PackedAnyException ex) = toException ex
