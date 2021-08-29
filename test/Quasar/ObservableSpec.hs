module Quasar.ObservableSpec (spec) where

import Quasar.Observable

import Control.Monad (void)
import Data.IORef
import Prelude
import Test.Hspec


spec :: Spec
spec = do
  mergeObservableSpec

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
      void $ unsafeAsyncObserveIO mergedObservable (writeIORef latestRef)
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
