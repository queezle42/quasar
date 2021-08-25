module Quasar.AsyncSpec (spec) where

import Control.Concurrent
import Control.Monad (void)
import Control.Monad.IO.Class
import Prelude
import Test.Hspec
import Quasar.Async
import Quasar.Awaitable
import System.Timeout

spec :: Spec
spec = parallel $ do
  describe "AsyncIO" $ do
    it "binds pure operations" $ do
      withDefaultAsyncManager (pure () >>= \() -> pure ())

    it "binds IO actions" $ do
      m1 <- newEmptyMVar
      m2 <- newEmptyMVar
      withDefaultAsyncManager (liftIO (putMVar m1 ()) >>= \() -> liftIO (putMVar m2 ()))
      tryTakeMVar m1 `shouldReturn` Just ()
      tryTakeMVar m2 `shouldReturn` Just ()

    xit "can continue after awaiting an already finished operation" $ do
      withDefaultAsyncManager (await =<< async (pure 42 :: AsyncIO Int)) `shouldReturn` 42

    it "can await the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultAsyncManager (await avar)

    it "can fmap the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultAsyncManager (id <$> await avar)

    it "can fmap the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultAsyncManager (id <$> await avar)

    it "can bind the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultAsyncManager (await avar >>= pure)

    it "can bind the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultAsyncManager (await avar >>= pure)

    it "can terminate when encountering an asynchronous exception" $ do
      never <- newAsyncVar :: IO (AsyncVar ())

      result <- timeout 100000 $ withDefaultAsyncManager $
        await never
      result `shouldBe` Nothing
