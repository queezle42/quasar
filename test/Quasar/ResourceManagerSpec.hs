module Quasar.ResourceManagerSpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Quasar.Prelude
import Test.Hspec
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.ResourceManager

data TestException = TestException
  deriving stock (Eq, Show)

instance Exception TestException

spec :: Spec
spec = parallel $ do
  describe "ResourceManager" $ do
    it "can be created" $ io do
      void newUnmanagedResourceManager

    it "can be created and disposed" $ io do
      resourceManager <- newUnmanagedResourceManager
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

    it "re-throws an exception" $ do
      shouldThrow
        do
          withResourceManager \_ ->
            throwIO TestException
        \TestException -> True

    it "cancels the main thread when a dispose action fails" $ do
      shouldThrow
        do
          withRootResourceManagerM do
            withSubResourceManagerM do
              registerDisposeAction $ throwIO TestException
            liftIO $ threadDelay 100000
            fail "Did not stop main thread on failing dispose action"
        \LinkedThreadDisposed -> True

    it "can attach an disposable that is disposed asynchronously" $ do
      withResourceManager \resourceManager -> do
        disposable <- attachDisposeAction resourceManager $ pure () <$ threadDelay 100000
        void $ forkIO $ disposeAndAwait disposable

    it "does not abort when encountering an exception" $ do
      var1 <- newTVarIO False
      var2 <- newTVarIO False
      shouldThrow
        do
          withRootResourceManagerM do
            registerDisposeAction $ pure () <$ (atomically (writeTVar var1 True))
            registerDisposeAction $ pure () <$ throwIO TestException
            registerDisposeAction $ pure () <$ (atomically (writeTVar var2 True))
        \LinkedThreadDisposed -> True
      atomically (readTVar var1) `shouldReturn` True
      atomically (readTVar var2) `shouldReturn` True
