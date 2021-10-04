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
      void newUnmanagedRootResourceManager

    it "can be created and disposed" $ io do
      resourceManager <- newUnmanagedRootResourceManager
      await =<< dispose resourceManager

    it "can be created and disposed" $ io do
      withRootResourceManager $ pure ()

    it "can be created and disposed with a delay" $ io do
      withRootResourceManager $ liftIO $ threadDelay 100000

    it "can \"dispose\" a noDisposable" $ io do
      withRootResourceManager do
        registerDisposable noDisposable

    it "can attach an disposable" $ io do
      withRootResourceManager do
        avar <- newAsyncVar
        registerDisposable $ alreadyDisposing avar
        putAsyncVar_ avar ()

    it "can dispose an awaitable that is completed asynchronously" $ io do
      avar <- newAsyncVar
      void $ forkIO $ do
        threadDelay 100000
        putAsyncVar_ avar ()

      withRootResourceManager do
        registerDisposable (alreadyDisposing avar)

    it "can call a trivial dispose action" $ io do
      withRootResourceManager do
        registerDisposeAction $ pure $ pure ()

    it "can call a dispose action" $ io do
      withRootResourceManager do
        avar <- newAsyncVar
        registerDisposeAction $ toAwaitable avar <$ putAsyncVar_ avar ()

    it "re-throws an exception" $ do
      shouldThrow
        do
          withRootResourceManager do
            liftIO $ throwIO TestException
        \TestException -> True

    it "cancels the main thread when a dispose action fails" $ io @() do
      withRootResourceManager do
        withSubResourceManagerM do
          registerDisposeAction $ throwIO TestException
        liftIO $ threadDelay 100000
        fail "Did not stop main thread on failing dispose action"

    it "can attach an disposable that is disposed asynchronously" $ io do
      withRootResourceManager do
        disposable <- captureDisposable_ $ registerDisposeAction $ pure () <$ threadDelay 100000
        liftIO $ void $ forkIO $ await =<< dispose disposable

    it "does not abort when encountering an exception" $ do
      var1 <- newTVarIO False
      var2 <- newTVarIO False
      withRootResourceManager do
        registerDisposeAction $ pure () <$ (atomically (writeTVar var1 True))
        registerDisposeAction $ pure () <$ throwIO TestException
        registerDisposeAction $ pure () <$ (atomically (writeTVar var2 True))
      atomically (readTVar var1) `shouldReturn` True
      atomically (readTVar var2) `shouldReturn` True
