module Quasar.ObservableSpec where

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
    it "merges correctly using getValue" $ do
      a <- newObservableVar ""
      b <- newObservableVar ""

      let mergedObservable = mergeObservable (\v0 v1 -> (v0, v1)) a b
      let latestShouldBe = (getValue mergedObservable `shouldReturn`)

      testSequence a b latestShouldBe

    it "merges correctly using subscribe" $ do
      a <- newObservableVar ""
      b <- newObservableVar ""

      let mergedObservable = mergeObservable (\v0 v1 -> (v0, v1)) a b
      (latestRef :: IORef (String, String)) <- newIORef ("", "")
      void $ subscribe mergedObservable (writeIORef latestRef . snd)
      let latestShouldBe = ((readIORef latestRef) `shouldReturn`)

      testSequence a b latestShouldBe
  where
    testSequence :: ObservableVar String -> ObservableVar String -> ((String, String) -> IO ()) -> IO ()
    testSequence a b latestShouldBe = do
      latestShouldBe ("", "")

      setValue a "a0"
      latestShouldBe ("a0", "")

      setValue b "b0"
      latestShouldBe ("a0", "b0")

      setValue a "a1"
      latestShouldBe ("a1", "b0")

      setValue b "b1"
      latestShouldBe ("a1", "b1")

      -- No change
      setValue a "a1"
      latestShouldBe ("a1", "b1")
