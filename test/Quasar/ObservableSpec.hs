module Quasar.ObservableSpec (spec) where

import Data.IORef
import Quasar.Prelude
import Quasar.Disposable
import Quasar.Observable
import Quasar.ResourceManager
import Test.Hspec


spec :: Spec
spec = do
  observableSpec
  mergeObservableSpec

observableSpec :: Spec
observableSpec = parallel do
  describe "Observable" do
    it "works" $ io do
      shouldReturn
        do
          withRootResourceManager do
            observeWhile (pure () :: Observable ()) toObservableUpdate
        ()


mergeObservableSpec :: Spec
mergeObservableSpec = do
  describe "mergeObservable" $ parallel $ do
    it "merges correctly using retrieveIO" $ do
      a <- newObservableVar ""
      b <- newObservableVar ""

      let mergedObservable = mergeObservable (,) a b
      let latestShouldBe = (retrieveIO mergedObservable `shouldReturn`)

      testSequence a b latestShouldBe

    it "merges correctly using observe" $ do
      a <- newObservableVar ""
      b <- newObservableVar ""

      let mergedObservable = mergeObservable (,) a b
      (latestRef :: IORef (ObservableMessage (String, String))) <- newIORef (ObservableUpdate ("", ""))
      void $ oldObserve mergedObservable (writeIORef latestRef)
      let latestShouldBe expected = do
            (ObservableUpdate x) <- readIORef latestRef
            x `shouldBe` expected

      testSequence a b latestShouldBe
  where
    testSequence :: ObservableVar String -> ObservableVar String -> ((String, String) -> IO ()) -> IO ()
    testSequence a b latestShouldBe = do
      latestShouldBe ("", "")

      setObservableVar a "a0"
      latestShouldBe ("a0", "")

      setObservableVar b "b0"
      latestShouldBe ("a0", "b0")

      setObservableVar a "a1"
      latestShouldBe ("a1", "b0")

      setObservableVar b "b1"
      latestShouldBe ("a1", "b1")

      -- No change
      setObservableVar a "a1"
      latestShouldBe ("a1", "b1")
