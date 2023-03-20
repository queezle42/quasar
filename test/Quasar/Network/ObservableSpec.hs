module Quasar.Network.ObservableSpec (spec) where

import Control.Monad.Catch
import Data.Maybe (fromJust)
import Quasar
import Quasar.Network.Runtime
import Quasar.Network.Runtime.Observable
import Quasar.Prelude
import System.Timeout (timeout)
import Test.Hspec.Core.Spec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions

spec :: Spec
spec = parallel $ describe "ObservableProxy" $ do
  it "transfers an initial value" $ fmap fromJust $ timeout 1_000_000 $ rm do
    var <- newObservableVarIO ("foobar" :: String)
    withStandaloneProxy (pure <$> toObservable var) \proxy -> do
      observeWith proxy \getNextValue -> do
        ObservableValue "foobar" <- atomically do
          getNextValue >>= \case
            ObservableLoading -> retry
            x -> pure x
        pure ()

  it "transfers layered initial values" $ fmap fromJust $ timeout 1_000_000 $ rm do
    inner <- newObservableVarIO ("foobar" :: String)
    outer <- newObservableVarIO (pure <$> toObservable inner :: Observable (ObservableState String))
    withStandaloneProxy (pure <$> toObservable outer :: Observable (ObservableState (Observable (ObservableState String)))) \outerProxy -> do
      let joinedObservable :: Observable (ObservableState String) = joinNetworkObservable outerProxy
      observeWith joinedObservable \getNextValue -> do
        ObservableValue "foobar" <- atomically do
          getNextValue >>= \case
            ObservableLoading -> retry
            x -> pure x
        pure ()
