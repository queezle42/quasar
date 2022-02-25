module Quasar.AsyncSpec (spec) where

--import Control.Concurrent
--import Control.Monad (void)
--import Control.Monad.IO.Class
import Prelude
import Test.Hspec
--import Quasar.Async
--import Quasar.Awaitable
--import Quasar.ResourceManager
--import System.Timeout

spec :: Spec
spec = describe "async" $ it "async" $ pendingWith "moving to new implementation..."
--spec = parallel $ do
--  describe "async" $ do
--    it "can pass a value through async and await" $ do
--      withRootResourceManager (await =<< async (pure 42)) `shouldReturn` (42 :: Int)
--
--    it "can pass a value through async and await" $ do
--      withRootResourceManager (await =<< async (liftIO (threadDelay 100000) >> pure 42)) `shouldReturn` (42 :: Int)
--
--  describe "await" $ do
--    it "can await the result of an async that is completed later" $ do
--      avar <- newAsyncVar :: IO (AsyncVar ())
--      void $ forkIO $ do
--        threadDelay 100000
--        putAsyncVar_ avar ()
--      await avar
--
--    it "can fmap the result of an already finished async" $ do
--      await (pure () :: Awaitable ()) :: IO ()
--
--    it "can terminate when encountering an asynchronous exception" $ do
--      never <- newAsyncVar :: IO (AsyncVar ())
--
--      result <- timeout 100000 $ withRootResourceManager $
--        await never
--      result `shouldBe` Nothing
