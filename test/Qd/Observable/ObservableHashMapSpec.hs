module Qd.Observable.ObservableHashMapSpec where

import Qd
import Qd.Observable.Delta
import qualified Qd.Observable.ObservableHashMap as OM

import Control.Monad (void)
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Prelude
import Test.Hspec

spec :: Spec
spec = parallel $ do
  describe "getValue" $ do
    it "returns the contents of the map" $ do
      om <- OM.new :: IO (OM.ObservableHashMap String String)
      getValue om `shouldReturn` HM.empty
      -- Evaluate unit for coverage
      () <- OM.insert "key" "value" om
      getValue om `shouldReturn` HM.singleton "key" "value"
      OM.insert "key2" "value2" om
      getValue om `shouldReturn` HM.fromList [("key", "value"), ("key2", "value2")]

  describe "subscribe" $ do
    it "calls the callback with the contents of the map" $ do
      lastCallbackValue <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)
      subscriptionHandle <- subscribe om $ writeIORef lastCallbackValue
      let lastCallbackShouldBe = (readIORef lastCallbackValue `shouldReturn`)

      lastCallbackShouldBe (Current, HM.empty)
      OM.insert "key" "value" om
      lastCallbackShouldBe (Update, HM.singleton "key" "value")
      OM.insert "key2" "value2" om
      lastCallbackShouldBe (Update, HM.fromList [("key", "value"), ("key2", "value2")])

      dispose subscriptionHandle
      lastCallbackShouldBe (Update, HM.fromList [("key", "value"), ("key2", "value2")])

      OM.insert "key3" "value3" om
      lastCallbackShouldBe (Update, HM.fromList [("key", "value"), ("key2", "value2")])

  describe "subscribeDelta" $ do
    it "calls the callback with changes to the map" $ do
      lastDelta <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)
      subscriptionHandle <- subscribeDelta om $ writeIORef lastDelta
      let lastDeltaShouldBe = (readIORef lastDelta `shouldReturn`)

      lastDeltaShouldBe $ Reset HM.empty
      OM.insert "key" "value" om
      lastDeltaShouldBe $ Add "key" "value"
      OM.insert "key" "changed" om
      lastDeltaShouldBe $ Change "key" "changed"
      OM.insert "key2" "value2" om
      lastDeltaShouldBe $ Add "key2" "value2"

      dispose subscriptionHandle
      lastDeltaShouldBe $ Add "key2" "value2"

      OM.insert "key3" "value3" om
      lastDeltaShouldBe $ Add "key2" "value2"

      void $ subscribeDelta om $ writeIORef lastDelta
      lastDeltaShouldBe $ Reset $ HM.fromList [("key", "changed"), ("key2", "value2"), ("key3", "value3")]

      OM.delete "key2" om
      lastDeltaShouldBe $ Remove "key2"

      OM.lookupDelete "key" om `shouldReturn` Just "changed"
      lastDeltaShouldBe $ Remove "key"

      getValue om `shouldReturn` HM.singleton "key3" "value3"

  describe "observeKey" $ do
    it "calls key callbacks with the correct value" $ do
      value1 <- newIORef undefined
      value2 <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)

      void $ subscribe (OM.observeKey "key1" om) (writeIORef value1)
      let v1ShouldBe = (readIORef value1 `shouldReturn`)

      v1ShouldBe $ (Current, Nothing)

      OM.insert "key1" "value1" om
      v1ShouldBe $ (Update, Just "value1")

      OM.insert "key2" "value2" om
      v1ShouldBe $ (Update, Just "value1")

      handle2 <- subscribe (OM.observeKey "key2" om) (writeIORef value2)
      let v2ShouldBe = (readIORef value2 `shouldReturn`)

      v1ShouldBe $ (Update, Just "value1")
      v2ShouldBe $ (Current, Just "value2")

      OM.insert "key2" "changed" om
      v1ShouldBe $ (Update, Just "value1")
      v2ShouldBe $ (Update, Just "changed")

      OM.delete "key1" om
      v1ShouldBe $ (Update, Nothing)
      v2ShouldBe $ (Update, Just "changed")

      -- Delete again (should have no effect)
      OM.delete "key1" om
      v1ShouldBe $ (Update, Nothing)
      v2ShouldBe $ (Update, Just "changed")

      getValue om `shouldReturn` HM.singleton "key2" "changed"
      -- Evaluate unit for coverage
      () <- dispose handle2

      OM.lookupDelete "key2" om `shouldReturn` (Just "changed")
      v2ShouldBe $ (Update, Just "changed")

      OM.lookupDelete "key2" om `shouldReturn` Nothing

      OM.lookupDelete "key1" om `shouldReturn` Nothing
      v1ShouldBe $ (Update, Nothing)

      getValue om `shouldReturn` HM.empty
