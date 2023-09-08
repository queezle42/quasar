module Quasar.Observable.ObservableVarSpec (spec) where

import Quasar.Observable.Core
import Quasar.Observable.ObservableVar
import Quasar.Prelude
import Test.Hspec


spec :: Spec
spec = parallel do
  describe "ObservableVar" do
    it "can be created" $ io do
      void $ newObservableVarIO (42 :: Int)

    it "can be read" $ io do
      var <- newObservableVarIO (42 :: Int)
      readObservableVarIO var `shouldReturn` 42

    it "can be read as an Observable" $ io do
      var <- newObservableVarIO (42 :: Int)
      let observable = toObservable var
      atomicallyC (readObservable @'[] observable) `shouldReturn` 42

    it "can be written" $ io do
      var <- newObservableVarIO (42 :: Int)
      readObservableVarIO var `shouldReturn` 42
      atomically $ writeObservableVar var 13
      readObservableVarIO var `shouldReturn` 13

    it "can be modified" $ io do
      var <- newObservableVarIO (42 :: Int)
      readObservableVarIO var `shouldReturn` 42
      atomically $ modifyObservableVar var (+ 1)
      readObservableVarIO var `shouldReturn` 43
