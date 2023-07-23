{-# LANGUAGE OverloadedLists #-}

module Quasar.Observable.ListSpec (spec) where

import Quasar.Observable.Core
import Quasar.Observable.List
import Quasar.Prelude
import Test.Hspec

spec :: Spec
spec = parallel do
  describe "applyDelta" do
    it "empty delta" do
      -- Edge case. Should not be sent usually, but can be expressed so it has
      -- to work.
      applyDelta @Seq @Int (ObservableListDelta mempty) (error "input list should not be evaluated") `shouldBe` Nothing

    it "empty insert" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 0 []]) [] `shouldBe` Nothing

    it "can insert element to empty list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 0 [42]]) [] `shouldBe` Just [42]

    it "can insert element at end of list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 3 [42]]) [1, 2, 3] `shouldBe` Just [1, 2, 3, 42]

    it "can insert element after end of list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 21 [42]]) [] `shouldBe` Just [42]
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 21 [42]]) [1, 2, 3] `shouldBe` Just [1, 2, 3, 42]

    it "can insert element at start of list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 0 [42]]) [1, 2, 3] `shouldBe` Just [42, 1, 2, 3]

    it "can insert element in the middle of the list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 2 [42]]) [1, 2, 3, 4] `shouldBe` Just [1, 2, 42, 3, 4]
      applyDelta @Seq @Int (ObservableListDelta [ObservableListInsert 2 [41, 42]]) [1, 2, 3, 4] `shouldBe` Just [1, 2, 41, 42, 3, 4]

    it "empty delete" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 0 0]) [1, 2, 3] `shouldBe` Nothing

    it "can delete elements" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 0 1]) [42, 1, 2, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 2 1]) [1, 2, 42, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 2 2]) [1, 2, 42, 43, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 4 1]) [1, 2, 3, 4, 42] `shouldBe` Just [1, 2, 3, 4]

    it "can clip delete operations at the end of the list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 4 21]) [1, 2, 3, 4, 42] `shouldBe` Just [1, 2, 3, 4]

    it "ignores delete operations after the end of the list" do
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 42 21]) [1, 2, 3, 4] `shouldBe` Nothing
      applyDelta @Seq @Int (ObservableListDelta [ObservableListDelete 0 13]) [] `shouldBe` Nothing

    it "applies complex operations" do
      let
        ops :: Seq (ObservableListOperation Int)
        ops = [
            ObservableListInsert 1 [42, 43],
            ObservableListDelete 1 1,
            ObservableListInsert 0 [44],
            ObservableListDelete 42 2 -- no-op
          ]
      applyDelta @Seq @Int (ObservableListDelta ops) [1, 2, 3, 4] `shouldBe` Just [1, 42, 43, 2, 44, 4]

  describe "mergeDelta" do
    it "works" do
      pendingWith "TODO"
