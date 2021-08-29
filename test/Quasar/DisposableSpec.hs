module Quasar.DisposableSpec (spec) where

import Control.Exception
import Control.Concurrent
import Quasar.Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Disposable

data TestException = TestException
  deriving stock (Eq, Show)

instance Exception TestException

spec :: Spec
spec = parallel $ do
  describe "Disposable" $ do
    describe "noDisposable" $ do
      it "can be disposed" $ do
        await =<< dispose noDisposable

      it "can be awaited" $ do
        await (isDisposed noDisposable)
        pure () :: IO ()

    describe "newDisposable" $ do
      it "signals it's disposed state" $ do
        disposable <- newDisposable $ pure $ pure ()
        void $ forkIO $ threadDelay 100000 >> disposeIO disposable
        await (isDisposed disposable)
        pure () :: IO ()

      it "can be disposed multiple times" $ do
        disposable <- newDisposable $ pure $ pure ()
        disposeIO disposable
        disposeIO disposable
        await (isDisposed disposable)

      it "can be disposed in parallel" $ do
        disposable <- newDisposable $ pure () <$ threadDelay 100000
        void $ forkIO $ disposeIO disposable
        disposeIO disposable
        await (isDisposed disposable)


  describe "ResourceManager" $ do
    it "can be created" $ io do
      void unsafeNewResourceManager

    it "can be created and disposed" $ do
      resourceManager <- unsafeNewResourceManager
      await =<< dispose resourceManager

    it "can be created and disposed" $ io do
      withResourceManager \_ -> pure ()

    it "can be created and disposed with a delay" $ do
      withResourceManager \_ -> threadDelay 100000

    it "can \"dispose\" a noDisposable" $ io do
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
        attachDisposeAction_ resourceManager $ pure $ pure ()
      pure () :: IO ()

    it "can call a dispose action" $ do
      withResourceManager \resourceManager -> do
        avar <- newAsyncVar :: IO (AsyncVar ())
        attachDisposeAction_ resourceManager $ toAwaitable avar <$ putAsyncVar_ avar ()
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
