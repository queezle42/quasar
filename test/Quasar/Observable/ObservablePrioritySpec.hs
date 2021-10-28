module Quasar.Observable.ObservablePrioritySpec (spec) where

import Control.Monad (void)
import Data.IORef
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Observable
import Quasar.Observable.ObservablePriority (ObservablePriority)
import Quasar.Observable.ObservablePriority qualified as OP
import Quasar.ResourceManager
import Quasar.Prelude
import Test.Hspec


shouldReturnM :: (Eq a, Show a, MonadIO m) => m a -> a -> m ()
shouldReturnM action expected = do
  result <- action
  liftIO $ result `shouldBe` expected


spec :: Spec
spec = do
  describe "ObservablePriority" $ parallel $ do
    it "can be created" $ io do
      void $ OP.create
    specify "retrieveIO returns the value with the highest priority" $ io $ withRootResourceManager do
      op :: ObservablePriority Int String <- OP.create
      p2 <- OP.insertValue op 2 "p2"
      (retrieve op >>= await) `shouldReturnM` Just "p2"
      p1 <- OP.insertValue op 1 "p1"
      (retrieve op >>= await) `shouldReturnM` Just "p2"
      dispose p2
      (retrieve op >>= await) `shouldReturnM` Just "p1"
      dispose p1
      (retrieve op >>= await) `shouldReturnM` Nothing
    it "sends updates when its value changes" $ io $ withRootResourceManager do
      result <- liftIO $ newIORef []
      let mostRecentShouldBe expected = liftIO do
            (ObservableUpdate x) <- (head <$> readIORef result)
            x `shouldBe` expected

      op :: ObservablePriority Int String <- OP.create
      _s <- observe op (liftIO . modifyIORef result . (:))
      mostRecentShouldBe Nothing
      p2 <- OP.insertValue op 2 "p2"

      mostRecentShouldBe (Just "p2")
      p1 <- OP.insertValue op 1 "p1"
      mostRecentShouldBe (Just "p2")
      dispose p2
      mostRecentShouldBe (Just "p1")
      dispose p1
      mostRecentShouldBe Nothing

      liftIO $ length <$> readIORef result `shouldReturn` 4
