module Quasar.AwaitableSpec (spec) where

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
  describe "Awaitable" $ do
    it "can await pure values" $ do
      awaitIO $ (pure () :: Awaitable ()) :: IO ()

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

      awaitIO avar

    it "can be awaited and completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()

      awaitIO avar


  describe "awaitAny" $ do
    it "works with completed awaitables" $ do
      awaitIO (awaitAny2 (pure () :: Awaitable ()) (pure () :: Awaitable ())) :: IO ()

    it "can be completed later" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar1 ()
      awaitIO (awaitAny2 avar1 avar2)

    it "can be completed later by the second parameter" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar2 ()
      awaitIO (awaitAny2 avar1 avar2)


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

    it "can fmap the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultAsyncManager (id <$> await avar)

    xit "can fmap the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultAsyncManager (id <$> await avar)

    it "can bind the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      withDefaultAsyncManager (await avar >>= pure)

    xit "can bind the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      withDefaultAsyncManager (await avar >>= pure)

    xit "can terminate when encountering an asynchronous exception" $ do
      never <- newAsyncVar :: IO (AsyncVar ())

      result <- timeout 100000 $ withDefaultAsyncManager $
        -- Use bind to create an AsyncIOPlumbing, which is the interesting case that uses `uninterruptibleMask` when run
        await never >>= pure
      result `shouldBe` Nothing
