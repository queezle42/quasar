module Quasar.AsyncSpec (spec) where

import Control.Concurrent
import Control.Monad (void)
import Control.Monad.IO.Class
import Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Core
import System.Timeout

spec :: Spec
spec = parallel $ do
  describe "AsyncVar" $ do
    it "can be created" $ do
      _ <- newAsyncVar :: IO (AsyncVar ())
      pure ()

    it "accepts a value" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()

  describe "AsyncIO" $ do
    it "binds pure operations" $ do
      withDefaultResourceManager (pure () >>= \() -> pure ())

    it "binds IO actions" $ do
      m1 <- newEmptyMVar
      m2 <- newEmptyMVar
      withDefaultResourceManager (liftIO (putMVar m1 ()) >>= \() -> liftIO (putMVar m2 ()))
      tryTakeMVar m1 `shouldReturn` Just ()
      tryTakeMVar m2 `shouldReturn` Just ()

    it "can continue after awaiting an already finished operation" $ do
      withDefaultResourceManager (await =<< async (pure 42 :: AsyncIO Int)) `shouldReturn` 42

    it "can fmap the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultResourceManager (id <$> await avar)

    it "can fmap the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultResourceManager (id <$> await avar)

    it "can bind the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultResourceManager (await avar >>= pure)

    it "can bind the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultResourceManager (await avar >>= pure)

    it "can terminate when encountering an asynchronous exception" $ do
      never <- newAsyncVar :: IO (AsyncVar ())

      result <- timeout 100000 $ withDefaultResourceManager $
        -- Use bind to create an AsyncIOPlumbing, which is the interesting case that uses `uninterruptibleMask` when run
        await never >>= pure
      result `shouldBe` Nothing
