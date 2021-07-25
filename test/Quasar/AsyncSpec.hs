module Quasar.AsyncSpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad (void)
import Control.Monad.IO.Class
import Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Core
import System.Timeout

shouldSatisfyM :: (HasCallStack, Show a) => IO a -> (a -> Bool) -> Expectation
shouldSatisfyM action expected = action >>= (`shouldSatisfy` expected)

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
      runAsyncIO (pure () >>= \() -> pure ())

    it "binds IO actions" $ do
      m1 <- newEmptyMVar
      m2 <- newEmptyMVar
      runAsyncIO (liftIO (putMVar m1 ()) >>= \() -> liftIO (putMVar m2 ()))
      tryTakeMVar m1 `shouldReturn` Just ()
      tryTakeMVar m2 `shouldReturn` Just ()

    it "can continue after awaiting an already finished operation" $ do
      runAsyncIO (await =<< async (pure 42 :: AsyncIO Int)) `shouldReturn` 42

    it "can fmap the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      runAsyncIO (id <$> await avar)

    it "can fmap the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      runAsyncIO (id <$> await avar)

    it "can bind the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar_ avar ()
      runAsyncIO (await avar >>= pure)

    it "can bind the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()
      runAsyncIO (await avar >>= pure)

    it "can terminate when encountering an asynchronous exception" $ do
      never <- newAsyncVar :: IO (AsyncVar ())

      result <- timeout 100000 $ runAsyncIO $
        -- Use bind to create an AsyncIOPlumbing, which is the interesting case that uses `uninterruptibleMask` when run
        await never >>= pure
      result `shouldBe` Nothing

  describe "CancellationToken" $ do
    it "propagates outer exceptions to the cancellation token" $ do
      result <- timeout 100000 $ withCancellationToken (runAsyncIO . await)
      result `shouldBe` Nothing

    it "can return a value after cancellation" $ do
      result <- timeout 100000 $ withCancellationToken (fmap (either (const True) (const False)) . atomically . awaitSTM)
      result `shouldBe` Just True
