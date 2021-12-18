module Quasar.AwaitableSpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Catch
import GHC.Conc (unsafeIOToSTM)
import Test.Hspec
import Quasar.Awaitable
import Quasar.Prelude

data TestException = TestException
  deriving stock (Eq, Show)

instance Exception TestException

spec :: Spec
spec = parallel $ do
  describe "Awaitable" $ do
    it "can await pure values" $ do
      await $ (pure () :: Awaitable ()) :: IO ()

  describe "AsyncVar" $ do
    it "can be created" $ do
      _ <- newAsyncVar :: IO (AsyncVar ())
      pure ()

    it "accepts a value" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()

    it "can be awaited" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()

      await avar

    it "can be awaited when completed asynchronously" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()

      await avar


  describe "awaitAny" $ do
    it "works with completed awaitables" $ do
      awaitAny2 (pure () :: Awaitable ()) (pure () :: Awaitable ()) :: IO ()

    it "can be completed later" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar1 ()
      awaitAny2 (await avar1) (await avar2)

    it "can be completed later by the second parameter" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar2 ()
      awaitAny2 (await avar1) (await avar2)
