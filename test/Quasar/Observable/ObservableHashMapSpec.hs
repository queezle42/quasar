module Quasar.Observable.ObservableHashMapSpec (spec) where

import Quasar.Disposable
import Quasar.Observable
import Quasar.Observable.Delta
import Quasar.Observable.ObservableHashMap qualified as OM

import Control.Monad (void)
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Prelude
import Test.Hspec

spec :: Spec
spec = parallel $ do
  describe "retrieveIO" $ do
    it "returns the contents of the map" $ do
      om <- OM.new :: IO (OM.ObservableHashMap String String)
      retrieveIO om `shouldReturn` HM.empty
      -- Evaluate unit for coverage
      () <- OM.insert "key" "value" om
      retrieveIO om `shouldReturn` HM.singleton "key" "value"
      OM.insert "key2" "value2" om
      retrieveIO om `shouldReturn` HM.fromList [("key", "value"), ("key2", "value2")]

  describe "subscribe" $ do
    it "calls the callback with the contents of the map" $ do
      lastCallbackValue <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)
      subscriptionHandle <- observe om $ writeIORef lastCallbackValue
      let lastCallbackShouldBe expected = do
            (ObservableUpdate update) <- readIORef lastCallbackValue
            update `shouldBe` expected

      lastCallbackShouldBe HM.empty
      OM.insert "key" "value" om
      lastCallbackShouldBe (HM.singleton "key" "value")
      OM.insert "key2" "value2" om
      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])

      disposeIO subscriptionHandle
      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])

      OM.insert "key3" "value3" om
      lastCallbackShouldBe (HM.fromList [("key", "value"), ("key2", "value2")])

  describe "subscribeDelta" $ do
    it "calls the callback with changes to the map" $ do
      lastDelta <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)
      subscriptionHandle <- subscribeDelta om $ writeIORef lastDelta
      let lastDeltaShouldBe = (readIORef lastDelta `shouldReturn`)

      lastDeltaShouldBe $ Reset HM.empty
      OM.insert "key" "value" om
      lastDeltaShouldBe $ Insert "key" "value"
      OM.insert "key" "changed" om
      lastDeltaShouldBe $ Insert "key" "changed"
      OM.insert "key2" "value2" om
      lastDeltaShouldBe $ Insert "key2" "value2"

      disposeIO subscriptionHandle
      lastDeltaShouldBe $ Insert "key2" "value2"

      OM.insert "key3" "value3" om
      lastDeltaShouldBe $ Insert "key2" "value2"

      void $ subscribeDelta om $ writeIORef lastDelta
      lastDeltaShouldBe $ Reset $ HM.fromList [("key", "changed"), ("key2", "value2"), ("key3", "value3")]

      OM.delete "key2" om
      lastDeltaShouldBe $ Delete "key2"

      OM.lookupDelete "key" om `shouldReturn` Just "changed"
      lastDeltaShouldBe $ Delete "key"

      retrieveIO om `shouldReturn` HM.singleton "key3" "value3"

  describe "observeKey" $ do
    it "calls key callbacks with the correct value" $ do
      value1 <- newIORef undefined
      value2 <- newIORef undefined

      om <- OM.new :: IO (OM.ObservableHashMap String String)

      void $ observe (OM.observeKey "key1" om) (writeIORef value1)
      let v1ShouldBe expected = do
            (ObservableUpdate update) <- readIORef value1
            update `shouldBe` expected

      v1ShouldBe $ Nothing

      OM.insert "key1" "value1" om
      v1ShouldBe $ Just "value1"

      OM.insert "key2" "value2" om
      v1ShouldBe $ Just "value1"

      handle2 <- observe (OM.observeKey "key2" om) (writeIORef value2)
      let v2ShouldBe expected = do
            (ObservableUpdate update) <- readIORef value2
            update `shouldBe` expected

      v1ShouldBe $ Just "value1"
      v2ShouldBe $ Just "value2"

      OM.insert "key2" "changed" om
      v1ShouldBe $ Just "value1"
      v2ShouldBe $ Just "changed"

      OM.delete "key1" om
      v1ShouldBe $ Nothing
      v2ShouldBe $ Just "changed"

      -- Delete again (should have no effect)
      OM.delete "key1" om
      v1ShouldBe $ Nothing
      v2ShouldBe $ Just "changed"

      retrieveIO om `shouldReturn` HM.singleton "key2" "changed"
      disposeIO handle2

      OM.lookupDelete "key2" om `shouldReturn` Just "changed"
      v2ShouldBe $ Just "changed"

      OM.lookupDelete "key2" om `shouldReturn` Nothing

      OM.lookupDelete "key1" om `shouldReturn` Nothing
      v1ShouldBe $ Nothing

      retrieveIO om `shouldReturn` HM.empty
