module Quasar.AwaitableSpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Catch
import GHC.Conc (unsafeIOToSTM)
import Test.Hspec
import Quasar.Future
import Quasar.Prelude

data TestException = TestException
  deriving stock (Eq, Show)

instance Exception TestException

spec :: Spec
spec = parallel $ do
  describe "Future" $ do
    it "can await pure values" $ do
      await $ (pure () :: Future ()) :: IO ()

  describe "Promise" $ do
    it "can be created" $ do
      _ <- newPromise :: IO (Promise ())
      pure ()

    it "accepts a value" $ do
      avar <- newPromise :: IO (Promise ())
      fulfillPromise avar ()

    it "can be awaited" $ do
      avar <- newPromise :: IO (Promise ())
      fulfillPromise avar ()

      await avar

    it "can be awaited when completed asynchronously" $ do
      avar <- newPromise :: IO (Promise ())
      void $ forkIO $ do
        threadDelay 100000
        fulfillPromise avar ()

      await avar


  describe "awaitAny" $ do
    it "works with completed awaitables" $ do
      awaitAny2 (pure () :: Future ()) (pure () :: Future ()) :: IO ()

    it "can be completed later" $ do
      avar1 <- newPromise :: IO (Promise ())
      avar2 <- newPromise :: IO (Promise ())
      void $ forkIO $ do
        threadDelay 100000
        fulfillPromise avar1 ()
      awaitAny2 (await avar1) (await avar2)

    it "can be completed later by the second parameter" $ do
      avar1 <- newPromise :: IO (Promise ())
      avar2 <- newPromise :: IO (Promise ())
      void $ forkIO $ do
        threadDelay 100000
        fulfillPromise avar2 ()
      awaitAny2 (await avar1) (await avar2)
