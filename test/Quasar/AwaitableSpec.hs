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
      awaitAny2 avar1 avar2

    it "can be completed later by the second parameter" $ do
      avar1 <- newAsyncVar :: IO (AsyncVar ())
      avar2 <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar2 ()
      awaitAny2 avar1 avar2

  describe "cacheAwaitable" do
    it "can cache an awaitable" $ io do
      var <- newTVarIO (0 :: Int)
      awaitable <- cacheAwaitable do
        unsafeAwaitSTM (modifyTVar var (+ 1)) :: Awaitable ()
      await awaitable
      await awaitable
      readTVarIO var `shouldReturn` 1

    it "can cache a bind" $ io do
      var1 <- newTVarIO (0 :: Int)
      var2 <- newTVarIO (0 :: Int)
      awaitable <- cacheAwaitable do
        unsafeAwaitSTM (modifyTVar var1 (+ 1)) >>= \_ -> unsafeAwaitSTM (modifyTVar var2 (+ 1)) :: Awaitable ()
      await awaitable
      await awaitable
      readTVarIO var1 `shouldReturn` 1
      readTVarIO var2 `shouldReturn` 1

    it "can cache an exception" $ io do
      var <- newMVar (0 :: Int)
      awaitable <- cacheAwaitable do
        unsafeAwaitSTM (unsafeIOToSTM (modifyMVar_ var (pure . (+ 1))) >> throwM TestException) :: Awaitable ()
      await awaitable `shouldThrow` \TestException -> True
      await awaitable `shouldThrow` \TestException -> True
      readMVar var `shouldReturn` 1

    it "can cache the left side of an awaitAny2" $ io do
      var <- newTVarIO (0 :: Int)

      let a1 = unsafeAwaitSTM (modifyTVar var (+ 1)) :: Awaitable ()
      let a2 = unsafeAwaitSTM retry :: Awaitable ()

      awaitable <- cacheAwaitable $ (awaitAny2 a1 a2 :: Awaitable ())

      await awaitable
      await awaitable
      readTVarIO var `shouldReturn` 1

    it "can cache the right side of an awaitAny2" $ io do
      var <- newTVarIO (0 :: Int)

      let a1 = unsafeAwaitSTM retry :: Awaitable ()
      let a2 = unsafeAwaitSTM (modifyTVar var (+ 1)) :: Awaitable ()

      awaitable <- cacheAwaitable $ (awaitAny2 a1 a2 :: Awaitable ())

      await awaitable
      await awaitable
      readTVarIO var `shouldReturn` 1

    it "can cache an mfix operation" $ io do
      avar <- newAsyncVar

      r <- cacheAwaitable $ do
        mfix \x -> do
          v <- await avar
          pure (v : x)

      peekAwaitable r `shouldReturn` Nothing

      putAsyncVar_ avar ()
      Just (():():():_) <- peekAwaitable r

      pure ()

