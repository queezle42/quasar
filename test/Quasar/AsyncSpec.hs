module Quasar.AsyncSpec (spec) where

import Control.Concurrent
import Control.Exception (throwIO)
import Control.Monad (void)
import Control.Monad.IO.Class
import Data.Either (isRight)
import Prelude
import Test.Hspec
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
      putAsyncVar avar ()

    it "calls a callback" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())

      mvar <- newEmptyMVar
      onResult_ avar throwIO (putMVar mvar)

      (() <$) <$> tryTakeMVar mvar `shouldReturn` Nothing

      putAsyncVar avar ()
      tryTakeMVar mvar `shouldSatisfyM` maybe False isRight

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
      putAsyncVar avar ()
      runAsyncIO (id <$> await avar)

    it "can fmap the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar avar ()
      runAsyncIO (id <$> await avar)

    it "can bind the result of an already finished async" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar avar ()
      runAsyncIO (await avar >>= pure)

    it "can bind the result of an async that is completed later" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar avar ()
      runAsyncIO (await avar >>= pure)

    it "can terminate when encountering an asynchronous exception" $ do
      never <- newAsyncVar :: IO (AsyncVar ())

      result <- timeout 100000 $ runAsyncIO $
        -- Use bind to create an AsyncIOPlumbing, which is the interesting case that uses `uninterruptibleMask` when run
        await never >>= pure
      result `shouldBe` Nothing
