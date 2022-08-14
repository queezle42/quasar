module Quasar.Network.ObservableSpec (spec) where

import Control.Monad.Catch
import Data.Maybe (fromJust)
import Quasar
import Quasar.Network.Runtime
import Quasar.Network.Runtime.Observable ()
import Quasar.Prelude
import System.Timeout (timeout)
import Test.Hspec.Core.Spec
import Test.Hspec.Expectations.Lifted
import Test.Hspec qualified as Hspec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions (stderrLogger LogLevelWarning)

shouldThrow :: (HasCallStack, Exception e, MonadQuasar m, MonadIO m) => QuasarIO a -> Hspec.Selector e -> m ()
shouldThrow action expected = do
  quasar <- askQuasar
  liftIO $ runQuasarIO quasar action `Hspec.shouldThrow` expected

spec :: Spec
spec = parallel $ describe "ObservableProxy" $ do
  it "transfers an initial value" $ rm do
    var <- newObservableVarIO ("foobar" :: String)
    withStandaloneProxy (toObservable var) \proxy -> do
      observeWith proxy \getNextValue -> do
        ObservableValue "foobar" <- atomically do
          getNextValue >>= \case
            ObservableLoading -> retry
            x -> pure x
        pure ()

  it "transfers layered initial values" $ fmap fromJust $ timeout 1000000 $ rm do
    inner <- newObservableVarIO ("foobar" :: String)
    outer <- newObservableVarIO (toObservable inner :: Observable String)
    withStandaloneProxy (toObservable outer :: Observable (Observable String)) \outerProxy -> do
      let joinedObservable :: Observable String = join outerProxy
      observeWith joinedObservable \getNextValue -> do
        ObservableValue "foobar" <- atomically do
          getNextValue >>= \case
            ObservableLoading -> retry
            x -> pure x
        pure ()
