module Quasar.Observable.ObservablePrioritySpec (spec) where

import Quasar.Disposable
import Quasar.Observable
import Quasar.Observable.ObservablePriority (ObservablePriority)
import Quasar.Observable.ObservablePriority qualified as OP

import Control.Monad (void)
import Data.IORef
import Prelude
import Test.Hspec


spec :: Spec
spec = do
  describe "ObservablePriority" $ parallel $ do
    it "can be created" $ do
      void $ OP.create
    specify "retrieveIO returns the value with the highest priority" $ do
      (op :: ObservablePriority Int String) <- OP.create
      p2 <- OP.insertValue op 2 "p2"
      retrieveIO op `shouldReturn` Just "p2"
      p1 <- OP.insertValue op 1 "p1"
      retrieveIO op `shouldReturn` Just "p2"
      disposeAndAwait p2
      retrieveIO op `shouldReturn` Just "p1"
      disposeAndAwait p1
      retrieveIO op `shouldReturn` Nothing
    it "sends updates when its value changes" $ do
      result <- newIORef []
      let mostRecentShouldBe expected = do
            (ObservableUpdate x) <- (head <$> readIORef result)
            x `shouldBe` expected

      (op :: ObservablePriority Int String) <- OP.create
      _s <- oldObserve op (modifyIORef result . (:))
      mostRecentShouldBe Nothing
      p2 <- OP.insertValue op 2 "p2"

      mostRecentShouldBe (Just "p2")
      p1 <- OP.insertValue op 1 "p1"
      mostRecentShouldBe (Just "p2")
      disposeAndAwait p2
      mostRecentShouldBe (Just "p1")
      disposeAndAwait p1
      mostRecentShouldBe Nothing

      length <$> readIORef result `shouldReturn` 4
