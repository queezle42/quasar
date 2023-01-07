module Control.Exception.ExSpec (
  spec,
) where

import Data.Either
import Data.Maybe
import Prelude
import Test.Hspec
import Control.Exception
import Control.Exception.Ex

data A = A
  deriving (Eq, Show)
instance Exception A

data B = B
  deriving (Eq, Show)
instance Exception B

data C = C
  deriving (Eq, Show)
instance Exception C


spec :: Spec
spec = describe "Ex" do
  describe "fromException" do
    it "matches exceptions in the list" do
      fromException @(Ex '[A, B, C]) (toException A)
        `shouldSatisfy`
          isJust

    it "matches exceptions later in the list" do
      fromException @(Ex '[A, B, C]) (toException C)
        `shouldSatisfy`
          isJust

    it "rejects exceptions that are not part of the list" do
      fromException @(Ex '[B, C]) (toException A)
        `shouldSatisfy`
          isNothing

  describe "toException" do
    it "fromException still works after quantification" do
      fromException @C (toException (toEx C :: Ex '[A, B, C]))
        `shouldSatisfy`
          isJust

  describe "matchEx" do
    it "can match the exception" do
      matchEx @C (toEx C :: Ex '[A, B, C])
        `shouldSatisfy`
          isRight

    it "fails to match another type" do
      let
        result :: Either (Ex '[A, B]) C
        result = matchEx (toEx B :: Ex '[A, B, C])
      result `shouldSatisfy` isLeft
