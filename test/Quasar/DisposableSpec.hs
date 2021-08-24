module Quasar.DisposableSpec (spec) where

import Control.Concurrent
import Control.Monad (void)
import Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Disposable

spec :: Spec
spec = parallel $ do
  describe "Disposable" $ do
    describe "noDisposable" $ do
      it "can be disposed" $ do
        awaitIO =<< dispose noDisposable

      it "can be awaited" $ do
        awaitIO (isDisposed noDisposable)
        pure () :: IO ()

  describe "ResourceManager" $ do
    it "can be created" $ do
      void newResourceManager

    it "can be created and disposed" $ do
      resourceManager <- newResourceManager
      awaitIO =<< dispose resourceManager

    it "can be created and disposed" $ do
      withResourceManager \_ -> pure ()

    it "can \"dispose\" a noDisposable" $ do
      withResourceManager \resourceManager -> do
        attachDisposable resourceManager noDisposable

    it "can dispose an awaitable that is completed asynchronously" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()

      withResourceManager \resourceManager -> do
        attachDisposable resourceManager (alreadyDisposing avar)
