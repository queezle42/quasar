module Quasar.Network.Runtime.FunctionSpec (spec) where

import Quasar
import Quasar.Network.Client
import Quasar.Prelude
import System.Timeout (timeout)
import Test.Hspec.Core.Spec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions

testTimeout :: Int -> IO () -> IO ()
testTimeout time fn =
  timeout time fn >>= \case
    Nothing -> fail $ mconcat ["Test reached timeout (", show time, "ns)"]
    Just () -> pure ()

spec :: Spec
spec = parallel $ describe "NetworkFunction" $ do
  it "can call a proxy function" $ testTimeout 1_000_000 $ rm do
    let
      theFunction  :: IO (FutureEx '[SomeException] Int)
      theFunction = do
        pure (pure 42)

    withStandaloneProxy theFunction \proxy -> do
      42 <- awaitEx =<< liftIO proxy
      pure ()

  it "can call a proxy function with an argument" $ testTimeout 1_000_000 $ rm do
    let
      theFunction  :: Int -> IO (FutureEx '[SomeException] Int)
      theFunction arg = do
        pure (pure (arg * 2))

    withStandaloneProxy theFunction \proxy -> do
      42 <- awaitEx =<< liftIO (proxy 21)
      pure ()
