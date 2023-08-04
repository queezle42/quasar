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
      pendingWith "TODO: detect no-op"
      -- Edge case. Should not be sent usually, but can be expressed so it has
      -- to work.
      applyDelta @Seq @Int (ListDelta mempty) (error "input list should not be evaluated") `shouldBe` Nothing

    it "keep elements" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3]) [1, 2, 3] `shouldBe` Just [1, 2, 3]
      applyDelta @Seq @Int (ListDelta [ListKeep 100]) [1, 2, 3] `shouldBe` Just [1, 2, 3]

    it "discards elements that are not kept" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3]) [1, 2, 3, 42] `shouldBe` Just [1, 2, 3]

    it "empty insert" do
      pendingWith "TODO: detect no-op"
      applyDelta @Seq @Int (ListDelta [ListInsert []]) [] `shouldBe` Nothing

    it "can insert element to empty list" do
      applyDelta @Seq @Int (ListDelta [ListInsert [42]]) [] `shouldBe` Just [42]

    it "can insert element at end of list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 3, ListInsert [42]]) [1, 2, 3] `shouldBe` Just [1, 2, 3, 42]

    it "can insert element after end of list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 21, ListInsert [42]]) [] `shouldBe` Just [42]
      applyDelta @Seq @Int (ListDelta [ListKeep 21, ListInsert [42]]) [1, 2, 3] `shouldBe` Just [1, 2, 3, 42]

    it "can insert element at start of list" do
      applyDelta @Seq @Int (ListDelta [ListInsert [42], ListKeep 3]) [1, 2, 3] `shouldBe` Just [42, 1, 2, 3]

    it "can insert element in the middle of the list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListInsert [42], ListKeep 2]) [1, 2, 3, 4] `shouldBe` Just [1, 2, 42, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListInsert [41, 42], ListKeep 2]) [1, 2, 3, 4] `shouldBe` Just [1, 2, 41, 42, 3, 4]

    it "empty delete" do
      pendingWith "TODO: detect no-op"
      applyDelta @Seq @Int (ListDelta [ListDrop 0, ListKeep 100]) [1, 2, 3] `shouldBe` Nothing

    it "can delete elements" do
      applyDelta @Seq @Int (ListDelta [ListDrop 1, ListKeep 100]) [42, 1, 2, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListDrop 1, ListKeep 100]) [1, 2, 42, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 2, ListDrop 2, ListKeep 100]) [1, 2, 42, 43, 3, 4] `shouldBe` Just [1, 2, 3, 4]
      applyDelta @Seq @Int (ListDelta [ListKeep 4, ListDrop 1, ListKeep 100]) [1, 2, 3, 4, 42] `shouldBe` Just [1, 2, 3, 4]

    it "can clip delete operations at the end of the list" do
      applyDelta @Seq @Int (ListDelta [ListKeep 4, ListDrop 21]) [1, 2, 3, 4, 42] `shouldBe` Just [1, 2, 3, 4]

    it "ignores delete operations after the end of the list" do
      pendingWith "TODO: detect no-op"
      applyDelta @Seq @Int (ListDelta [ListKeep 42, ListDrop 21]) [1, 2, 3, 4] `shouldBe` Nothing
      applyDelta @Seq @Int (ListDelta [ListDrop 13]) [] `shouldBe` Nothing

    it "applies complex operations" do
      let
        ops :: [ListOperation Int]
        ops = [
            ListKeep 1,
            ListInsert [42, 43],
            ListKeep 1,
            ListDrop 1,
            ListInsert [44],
            ListKeep 42, -- clipped to length of list
            ListDrop 2 -- no-op
          ]
      applyDelta @Seq @Int (ListDelta ops) [1, 2, 3, 4] `shouldBe` Just [1, 42, 43, 2, 44, 4]

  describe "mergeDelta" do
    it "works" do
      pendingWith "TODO"
