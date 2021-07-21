module Quasar.AsyncSpec (spec) where

import Control.Concurrent
import Control.Exception (throwIO)
import Control.Monad.IO.Class
import Data.Either (isRight)
import Prelude
import Test.Hspec
import Quasar.Core

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
      onResult_ throwIO avar (putMVar mvar)

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
