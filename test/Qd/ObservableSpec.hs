module Qd.ObservableSpec where

import Test.Hspec

import Qd.Observable

import Control.Monad (void)
import Data.IORef

spec :: Spec
spec = do
  mergeObservableSpec

mergeObservableSpec :: Spec
mergeObservableSpec = do
  describe "mergeObservable" $ parallel $ do
    it "merges correctly using getValue" $ do
      a <- newObservableVar Nothing
      b <- newObservableVar Nothing

      let mergedObservable = mergeObservable (\v0 v1 -> Just (v0, v1)) a b
      let latestShouldBe = (getValue mergedObservable `shouldReturn`) . Just

      testSequence a b latestShouldBe

    it "merges correctly using subscribe" $ do
      a <- newObservableVar Nothing
      b <- newObservableVar Nothing

      let mergedObservable = mergeObservable (\v0 v1 -> Just (v0, v1)) a b
      (latestRef :: IORef (Maybe (Maybe String, Maybe String))) <- newIORef Nothing
      void $ subscribe mergedObservable (writeIORef latestRef . snd)
      let latestShouldBe = ((readIORef latestRef) `shouldReturn`) . Just

      testSequence a b latestShouldBe
  where
    testSequence :: ObservableVar String -> ObservableVar String -> ((Maybe String, Maybe String) -> IO ()) -> IO ()
    testSequence a b latestShouldBe = do
      latestShouldBe (Nothing, Nothing)

      setValue a "a0"
      latestShouldBe (Just "a0", Nothing)

      setValue b "b0"
      latestShouldBe (Just "a0", Just "b0")

      setValue a "a1"
      latestShouldBe (Just "a1", Just "b0")

      setValue b "b1"
      latestShouldBe (Just "a1", Just "b1")

      -- No change
      setValue a "a1"
      latestShouldBe (Just "a1", Just "b1")
