module Quasar.ResourcesSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Exceptions.ExceptionSink
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources
import Quasar.Utils.Exceptions
import Test.Hspec

data TestException = TestException
  deriving stock (Eq, Show)

instance Exception TestException

withTestExceptionSink :: TIOWorker -> (ExceptionSink -> IO a) -> IO a
withTestExceptionSink worker action = do
  (sink, collect) <- atomically $ newExceptionCollector (loggingExceptionSink worker)
  result <- action sink
  mapM_ throwM . mkCombinedException =<< atomicallyC (liftSTMc collect)
  pure result

spec :: Spec
spec = parallel $ do
  describe "Disposer" $ do
    describe "trivial disposable" $ do
      it "can be disposed" $ io do
        dispose trivialDisposer

      it "can be awaited" $ io do
        await (isDisposed trivialDisposer)

    describe "Disposer" $ do
      it "can be disposed" $ io do
        worker <- newTIOWorker
        withTestExceptionSink worker \sink -> do
          markVar <- newTVarIO False
          disposable <- atomically $ newUnmanagedIODisposer (atomically (writeTVar markVar True)) worker sink
          dispose disposable
          readTVarIO markVar `shouldReturn` True

      it "signals it's disposed state" $ io do
        worker <- newTIOWorker
        withTestExceptionSink worker \sink -> do
          disposable <- atomically $ newUnmanagedIODisposer (pure ()) worker sink
          void $ forkIO $ threadDelay 100000 >> dispose disposable
          await (isDisposed disposable)

      it "can be disposed multiple times" $ io do
        worker <- newTIOWorker
        withTestExceptionSink worker \sink -> do
          disposable <- atomically $ newUnmanagedIODisposer (pure ()) worker sink
          dispose disposable
          dispose disposable
          await (isDisposed disposable)

      it "can be disposed in parallel" $ do
        worker <- newTIOWorker
        withTestExceptionSink worker \sink -> do
          disposable <- atomically $ newUnmanagedIODisposer (threadDelay 100000) worker sink
          void $ forkIO $ dispose disposable
          dispose disposable
          await (isDisposed disposable)

    describe "STM Disposer" $ do
      it "can be disposed" $ io do
        worker <- newTIOWorker
        withTestExceptionSink worker \sink -> do
          markVar <- newTVarIO False
          disposable <- atomically $ newUnmanagedSTMDisposer (writeTVar markVar True) worker sink
          dispose disposable
          readTVarIO markVar `shouldReturn` True

    describe "TSimpleDisposer" $ do
      it "can be disposed" $ io do
        markVar <- newTVarIO False
        disposable <- atomically $ newUnmanagedTSimpleDisposer (writeTVar markVar True)
        dispose disposable
        readTVarIO markVar `shouldReturn` True

--  describe "ResourceManager" $ do
--    it "can be created" $ io do
--      withRootResourceManager $ pure ()
--
--    it "can be created and disposed" $ io do
--      withRootResourceManager do
--        resourceManager <- askResourceManager
--        disposeEventually_ resourceManager
--
--    it "is disposed when exiting withRootResourceManager" $ io do
--      resourceManager <- withRootResourceManager askResourceManager
--
--      peekFuture (isDisposed resourceManager) `shouldReturn` Just ()
--
--    it "can be created and disposed with a delay" $ io do
--      withRootResourceManager $ liftIO $ threadDelay 100000
--
--    it "can \"dispose\" a noDisposable" $ io do
--      withRootResourceManager do
--        registerDisposable noDisposable
--
--    it "can attach a dispose action" $ io do
--      var <- newTVarIO False
--      withRootResourceManager do
--        registerDisposeAction $ atomically $ writeTVar var True
--
--      atomically (readTVar var) `shouldReturn` True
--
--    it "can attach a slow dispose action" $ io do
--      withRootResourceManager do
--        registerDisposeAction $ threadDelay 100000
--
--    it "re-throws an exception" $ do
--      shouldThrow
--        do
--          withRootResourceManager do
--            liftIO $ throwIO TestException
--        \TestException -> True
--
--    it "handles an exception while disposing" $ io do
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          registerDisposeAction $ throwIO TestException
--          liftIO $ threadDelay 100000
--
--    it "passes an exception to the root resource manager" $ io do
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          withScopedResourceManager do
--            registerDisposeAction $ throwIO TestException
--            liftIO $ threadDelay 100000
--
--    it "passes an exception to the root resource manager when closing the inner resource manager first" $ io do
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          withScopedResourceManager do
--            registerDisposeAction $ throwIO TestException
--          liftIO $ threadDelay 100000
--
--    it "can attach an disposable that is disposed asynchronously" $ io do
--      withRootResourceManager do
--        disposable <- captureDisposable_ $ registerDisposeAction $ threadDelay 100000
--        liftIO $ void $ forkIO $ dispose disposable
--
--    it "does not abort disposing when encountering an exception" $ do
--      var1 <- newTVarIO False
--      var2 <- newTVarIO False
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          registerDisposeAction $ atomically (writeTVar var1 True)
--          registerDisposeAction $ throwIO TestException
--          registerDisposeAction $ atomically (writeTVar var2 True)
--      atomically (readTVar var1) `shouldReturn` True
--      atomically (readTVar var2) `shouldReturn` True
--
--    it "withRootResourceManager will start disposing when receiving an exception" $ io do
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          linkExecution do
--            throwToResourceManager TestException
--            sleepForever
--
--    it "combines exceptions from resources with exceptions on the thread" $ io do
--      (`shouldThrow` \(combinedExceptions -> exceptions) -> length exceptions == 2) do
--        withRootResourceManager do
--          throwToResourceManager TestException
--          throwM TestException
--
--    it "can dispose a resource manager loop" $ io do
--      withRootResourceManager do
--        rm1 <- newResourceManager
--        rm2 <- newResourceManager
--        liftIO $ atomically do
--          attachDisposable rm1 rm2
--          attachDisposable rm2 rm1
--
--    it "can dispose a resource manager loop" $ io do
--      withRootResourceManager do
--        rm1 <- newResourceManager
--        rm2 <- newResourceManager
--        liftIO $ atomically do
--          attachDisposable rm1 rm2
--          attachDisposable rm2 rm1
--        dispose rm1
--
--    it "can dispose a resource manager loop with a shared disposable" $ io do
--      var <- newTVarIO (0 :: Int)
--      d <- atomically $ newDisposable $ atomically $ modifyTVar var (+ 1)
--      withRootResourceManager do
--        rm1 <- newResourceManager
--        rm2 <- newResourceManager
--        liftIO $ atomically do
--          attachDisposable rm1 rm2
--          attachDisposable rm2 rm1
--          attachDisposable rm1 d
--          attachDisposable rm2 d
--
--      atomically (readTVar var) `shouldReturn` 1
--
--
--  describe "linkExecution" do
--    it "does not generate an exception after it is completed" $ io do
--      (`shouldThrow` \(_ :: CombinedException) -> True) do
--        withRootResourceManager do
--          linkExecution do
--            pure ()
--          throwToResourceManager TestException
--          liftIO $ threadDelay 100000
