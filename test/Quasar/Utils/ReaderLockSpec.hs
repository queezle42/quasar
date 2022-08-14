module Quasar.Utils.ReaderLockSpec (spec) where

import Test.Hspec
import Quasar.Prelude
import Quasar.Utils.ReaderLock

spec :: Spec
spec = parallel do
  describe "ReaderLock" do
    it @(IO ()) "can be created" do
      _rl <- atomically $ newReaderLock (pure ()) (pure ())
      pure ()

    it @(IO ()) "can be locked" do
      var <- newTVarIO (0 :: Integer)
      rl <- atomically $ newReaderLock (modifyTVar var succ) (modifyTVar var pred)
      withReaderLock rl do
        readTVarIO var `shouldReturn` 1

      readTVarIO var `shouldReturn` 0

    it @(IO ()) "can be locked multiple times" do
      var <- newTVarIO (0 :: Integer)
      rl <- atomically $ newReaderLock (modifyTVar var succ) (modifyTVar var pred)
      withReaderLock rl do
        readTVarIO var `shouldReturn` 1

      readTVarIO var `shouldReturn` 0

      withReaderLock rl do
        readTVarIO var `shouldReturn` 1

      readTVarIO var `shouldReturn` 0

    it @(IO ()) "can be locked nested" do
      var <- newTVarIO (0 :: Integer)
      rl <- atomically $ newReaderLock (modifyTVar var succ) (modifyTVar var pred)
      withReaderLock rl do
        withReaderLock rl do
          readTVarIO var `shouldReturn` 1

      readTVarIO var `shouldReturn` 0

    it @(IO ()) "can be destroyed" do
      rl <- atomically $ newReaderLock (pure ()) (pure ())
      withReaderLock rl do
        atomically (tryDestroyReaderLock rl) `shouldReturn` False

      atomically (tryDestroyReaderLock rl) `shouldReturn` True

      withReaderLock rl (pure ()) `shouldThrow` isReaderLockDestroyed

  describe "ReaderLock (recursive)" do
    it @(IO ()) "works" do
      var <- newTVarIO (0 :: Integer)
      x <- atomically $ newReaderLock (modifyTVar var succ) (modifyTVar var pred)
      y <- atomically $ newRecursiveReaderLock x
      withReaderLock y do
        readTVarIO var `shouldReturn` 1
        atomically (tryDestroyReaderLock y) `shouldReturn` False
        atomically (tryDestroyReaderLock x) `shouldReturn` False

      readTVarIO var `shouldReturn` 0

      withReaderLock x do
        withReaderLock y do
          readTVarIO var `shouldReturn` 1

        readTVarIO var `shouldReturn` 1

        atomically (tryDestroyReaderLock y) `shouldReturn` True

        withReaderLock y (pure ()) `shouldThrow` isReaderLockDestroyed

    it @(IO ()) "cannot be locked if the parent lock is destroyed" do
      var <- newTVarIO (0 :: Integer)
      x <- atomically $ newReaderLock (modifyTVar var succ) (modifyTVar var pred)
      y <- atomically $ newRecursiveReaderLock x

      atomically (tryDestroyReaderLock x) `shouldReturn` True

      withReaderLock y (pure ()) `shouldThrow` isReaderLockDestroyed

