module Quasar.AsyncSpec (spec) where

import Control.Applicative (liftA2)
import Control.Concurrent
import Control.Monad.IO.Class
import Prelude
import Test.Hspec
import Quasar.Core

spec :: Spec
spec = parallel $ do
  describe "AsyncVar" $ parallel $ do
    it "can be created" $ do
      _ <- newAsyncVar :: IO (AsyncVar ())
      pure ()

    it "accepts a value" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      putAsyncVar avar ()

    it "calls a callback" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())

      mvar <- newEmptyMVar
      avar `onResult_` putMVar mvar

      tryTakeMVar mvar `shouldReturn` Nothing

      putAsyncVar avar ()
      tryTakeMVar mvar `shouldReturn` Just ()

  describe "AsyncIO" $ parallel $ do
    it "binds pure operations" $ do
      runAsyncIO (pure () >>= \() -> pure ())

    it "binds IO actions" $ do
      m1 <- newEmptyMVar
      m2 <- newEmptyMVar
      runAsyncIO (liftIO (putMVar m1 ()) >>= \() -> liftIO (putMVar m2 ()))
      tryTakeMVar m1 `shouldReturn` Just ()
      tryTakeMVar m2 `shouldReturn` Just ()

    it "can continue after awaiting an already finished operation" $ do
      runAsyncIO (await (pure 42 :: Async Int)) `shouldReturn` 42

    it "can continue after awaiting an async that itself finishes afterwards" $ do
      avar <- newAsyncVar
      runAsyncIO $ await avar *> putAsyncVar avar ()

    it "liftA2" $ do
      avar <- newAsyncVar
      runAsyncIO (liftA2 (,) (await avar) (putAsyncVar avar 42)) `shouldReturn` (42 :: Int, ())

    it "can continue after blocking on an async that is completed from another thread" $ do
      a1 <- newAsyncVar
      a2 <- newAsyncVar
      a3 <- newAsyncVar
      a4 <- newAsyncVar
      _ <- forkIO $ runAsyncIO $ await a1 >>= putAsyncVar a2 >> await a3 >>= putAsyncVar a4
      runAsyncIO ((await a2 >> (await a4 *> putAsyncVar a3 1)) *> putAsyncVar a1 41)
      liftA2 (+) (wait a2) (wait a4) `shouldReturn` (42 :: Int)
