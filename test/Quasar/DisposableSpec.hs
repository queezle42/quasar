module Quasar.DisposableSpec (spec) where

import Control.Exception
import Control.Concurrent
import Control.Monad (void)
import Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Disposable

data TestException = TestException
  deriving (Eq, Show)

instance Exception TestException

spec :: Spec
spec = parallel $ do
  describe "Disposable" $ do
    describe "noDisposable" $ do
      it "can be disposed" $ do
        awaitIO =<< dispose noDisposable

      it "can be awaited" $ do
        awaitIO (isDisposed noDisposable)
        pure () :: IO ()

    describe "newDisposable" $ do
      it "signals it's disposed state" $ do
        disposable <- newDisposable $ pure $ pure ()
        void $ forkIO $ threadDelay 100000 >> disposeIO disposable
        awaitIO (isDisposed disposable)
        pure () :: IO ()

      it "can be disposed multiple times" $ do
        disposable <- newDisposable $ pure $ pure ()
        disposeIO disposable
        disposeIO disposable
        awaitIO (isDisposed disposable)

      it "can be disposed in parallel" $ do
        disposable <- newDisposable $ pure () <$ threadDelay 100000
        void $ forkIO $ disposeIO disposable
        disposeIO disposable
        awaitIO (isDisposed disposable)


  describe "ResourceManager" $ do
    it "can be created" $ do
      void unsafeNewResourceManager

    it "can be created and disposed" $ do
      resourceManager <- unsafeNewResourceManager
      awaitIO =<< dispose resourceManager

    it "can be created and disposed" $ do
      withResourceManager \_ -> pure ()

    it "can be created and disposed with a delay" $ do
      withResourceManager \_ -> threadDelay 100000

    it "can \"dispose\" a noDisposable" $ do
      withResourceManager \resourceManager -> do
        attachDisposable resourceManager noDisposable

    it "can attach an disposable" $ do
      withResourceManager \resourceManager -> do
        avar <- newAsyncVar :: IO (AsyncVar ())
        attachDisposable resourceManager $ alreadyDisposing avar
        putAsyncVar_ avar ()
      pure () :: IO ()

    it "can dispose an awaitable that is completed asynchronously" $ do
      avar <- newAsyncVar :: IO (AsyncVar ())
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()

      withResourceManager \resourceManager -> do
        attachDisposable resourceManager (alreadyDisposing avar)

    it "can call a trivial dispose action" $ do
      withResourceManager \resourceManager ->
        attachDisposeAction resourceManager $ pure $ pure ()
      pure () :: IO ()

    it "can call a dispose action" $ do
      withResourceManager \resourceManager -> do
        avar <- newAsyncVar :: IO (AsyncVar ())
        attachDisposeAction resourceManager $ toAwaitable avar <$ putAsyncVar_ avar ()
      pure () :: IO ()

    it "re-throws an exception from a dispose action" $ do
      shouldThrow
        do
          withResourceManager \resourceManager ->
            attachDisposeAction resourceManager $ throwIO $ TestException
        \TestException -> True

    it "can attach an disposable that is disposed asynchronously" $ do
      withResourceManager \resourceManager -> do
        disposable <- attachDisposeAction resourceManager $ pure () <$ threadDelay 100000
        void $ forkIO $ disposeIO disposable
