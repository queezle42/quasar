module Quasar.Network.Runtime.ObservableSpec (spec) where

import Data.Maybe (fromJust)
import Quasar
import Quasar.Network.Client
import Quasar.Network.Runtime
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
spec = pure ()
--spec = parallel $ describe "ObservableProxy" $ do
--  it "transfers an initial value" $ fmap fromJust $ timeout 1_000_000 $ rm do
--    var <- newObservableVarIO ("foobar" :: String)
--    withStandaloneProxy (pure <$> toObservable var) \proxy -> do
--      observeWith proxy \getNextValue -> do
--        ObservableValue "foobar" <- atomicallyC do
--          getNextValue >>= \case
--            ObservableLoading -> retry
--            x -> pure x
--        pure ()
--
--  it "transfers layered initial values" $ testTimeout 1_000_000 $ rm do
--    inner <- newObservableVarIO ("foobar" :: String)
--    outer <- newObservableVarIO (pure <$> toObservable inner :: Observable (ObservableState String))
--    withStandaloneProxy (pure <$> toObservable outer :: Observable (ObservableState (Observable (ObservableState String)))) \outerProxy -> do
--      let joinedObservable :: Observable (ObservableState String) = joinNetworkObservable outerProxy
--      observeWith joinedObservable \getNextValue -> do
--        ObservableValue "foobar" <- atomicallyC do
--          getNextValue >>= \case
--            ObservableLoading -> retry
--            x -> pure x
--        pure ()
