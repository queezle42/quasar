module Quasar.ObservableSpec (spec) where

import Quasar.Observable.Core
import Quasar.Prelude
import Test.Hspec


spec :: Spec
spec = parallel do
  describe "Applicative" do
    describe "pure" do
      it "can be read" do
        atomicallyC (readObservable# (pure 42 :: Observable NoLoad '[] Int)) `shouldReturn` 42
