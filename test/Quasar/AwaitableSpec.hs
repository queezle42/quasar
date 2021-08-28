module Quasar.AwaitableSpec (spec) where

import Control.Concurrent
import Control.Monad (void)
import Prelude
import Test.Hspec
import Quasar.Awaitable

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
      await (awaitAny2 (pure () :: Awaitable ()) (pure () :: Awaitable ())) :: IO ()

    it "can be completed later" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar1 ()
      await (awaitAny2 avar1 avar2)

    it "can be completed later by the second parameter" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar2 ()
      await (awaitAny2 avar1 avar2)
