module Quasar.Network.Runtime.GenericSpec (spec) where

import Quasar
import Quasar.Network
import Quasar.Network.Client
import Quasar.Prelude
import System.Timeout (timeout)
import Test.Hspec.Core.Spec

rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions

testTimeout :: Int -> IO () -> IO ()
testTimeout time fn =
  timeout time fn >>= \case
    Nothing -> fail $ mconcat ["Test reached timeout (", show time, "ns)"]
    Just () -> pure ()

data Unit = Unit
  deriving Generic

instance NetworkObject Unit where
  type NetworkStrategy Unit = Generic

data Product a = Product a (FutureEx '[SomeException] Int)
  deriving Generic

instance NetworkObject a => NetworkObject (Product a) where
  type NetworkStrategy (Product a) = Generic

data Sum a
  = S1 Int
  | S2 (FutureEx '[SomeException] Bool)
  | S3 a
  deriving Generic

instance NetworkObject a => NetworkObject (Sum a) where
  type NetworkStrategy (Sum a) = Generic

spec :: Spec
spec = parallel do
  describe "Unit" do
    it "can transfer ()" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure () :: FutureEx '[SomeException] ()) \future -> do
        () <- await future
        pure ()

    it "can transfer a custom unit" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure Unit :: FutureEx '[SomeException] Unit) \future -> do
        Unit <- await future
        pure ()

  describe "Product" do
    it "can transfer a tuple" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure (42, True) :: FutureEx '[SomeException] (Int, Bool)) \proxy -> do
        (42, True) <- await proxy
        pure ()

    it "can transfer a product type" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure (Product () (pure 42)) :: FutureEx '[SomeException] (Product ())) \proxy -> do
        (Product () future) <- await proxy
        42 <- await future
        pure ()

  describe "Sum" do
    it "can transfer a simple value over a sum type" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure (S1 42) :: FutureEx '[SomeException] (Sum ())) \proxy -> do
        (S1 42) <- await proxy
        pure ()

    it "can transfer a network reference over a sum type" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure (S2 (pure True)) :: FutureEx '[SomeException] (Sum ())) \proxy -> do
        (S2 future) <- await proxy
        True <- await future
        pure ()

    it "can transfer a parametrized value over a sum type" $ testTimeout 1_000_000 $ rm do
      withStandaloneProxy (pure (S3 ()) :: FutureEx '[SomeException] (Sum ())) \proxy -> do
        (S3 ()) <- await proxy
        pure ()
