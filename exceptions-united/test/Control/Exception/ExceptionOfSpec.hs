module Control.Exception.ExceptionOfSpec (
  spec,
) where

import Data.Either
import Data.Maybe
import Prelude
import Test.Hspec
import Control.Exception
import Control.Exception.ExceptionOf

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
spec = describe "ExceptionOf" do
  describe "fromException" do
    it "matches exceptions in the list" do
      fromException @(ExceptionOf '[A, B, C]) (toException A)
        `shouldSatisfy`
          isJust

    it "matches exceptions later in the list" do
      fromException @(ExceptionOf '[A, B, C]) (toException C)
        `shouldSatisfy`
          isJust

    it "rejects exceptions that are not part of the list" do
      fromException @(ExceptionOf '[B, C]) (toException A)
        `shouldSatisfy`
          isNothing

  describe "toException" do
    it "fromException still works after quantification" do
      fromException @C (toException (toExceptionOf C :: ExceptionOf '[A, B, C]))
        `shouldSatisfy`
          isJust

  describe "matchExceptionOf" do
    it "can match the exception" do
      matchExceptionOf @C (toExceptionOf C :: ExceptionOf '[A, B, C])
        `shouldSatisfy`
          isRight

    it "fails to match another type" do
      let
        result :: Either (ExceptionOf '[A, B]) C
        result = matchExceptionOf (toExceptionOf B :: ExceptionOf '[A, B, C])
      result `shouldSatisfy` isLeft
