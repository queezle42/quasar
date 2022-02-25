module Quasar.ObservableSpec (spec) where

--import Data.IORef
import Quasar.Prelude
--import Quasar.Awaitable
--import Quasar.Observable
--import Quasar.ResourceManager
import Test.Hspec


spec :: Spec
spec = pure ()
--spec = do
--  observableSpec
--  mergeObservableSpec
--
--observableSpec :: Spec
--observableSpec = parallel do
--  describe "Observable" do
--    it "works" $ io do
--      shouldReturn
--        do
--          withRootResourceManager do
--            observeWhile (pure () :: Observable ()) toObservableUpdate
--        ()
--
--
--mergeObservableSpec :: Spec
--mergeObservableSpec = do
--  describe "mergeObservable" $ parallel $ do
--    it "merges correctly using retrieveIO" $ io $ withRootResourceManager do
--      a <- newObservableVar ""
--      b <- newObservableVar ""
--
--      let mergedObservable = liftA2 (,) (toObservable a) (toObservable b)
--      let latestShouldBe val = retrieve mergedObservable >>= await >>= liftIO . (`shouldBe` val)
--
--      testSequence a b latestShouldBe
--
--    it "merges correctly using observe" $ io $ withRootResourceManager do
--      a <- newObservableVar ""
--      b <- newObservableVar ""
--
--      let mergedObservable = liftA2 (,) (toObservable a) (toObservable b)
--      (latestRef :: IORef (ObservableMessage (String, String))) <- liftIO $ newIORef (ObservableUpdate ("", ""))
--      void $ observe mergedObservable (liftIO . writeIORef latestRef)
--      let latestShouldBe expected = liftIO do
--            (ObservableUpdate x) <- readIORef latestRef
--            x `shouldBe` expected
--
--      testSequence a b latestShouldBe
--  where
--    testSequence :: ObservableVar String -> ObservableVar String -> ((String, String) -> ResourceManagerIO ()) -> ResourceManagerIO ()
--    testSequence a b latestShouldBe = do
--      latestShouldBe ("", "")
--
--      setObservableVar a "a0"
--      latestShouldBe ("a0", "")
--
--      setObservableVar b "b0"
--      latestShouldBe ("a0", "b0")
--
--      setObservableVar a "a1"
--      latestShouldBe ("a1", "b0")
--
--      setObservableVar b "b1"
--      latestShouldBe ("a1", "b1")
--
--      -- No change
--      setObservableVar a "a1"
--      latestShouldBe ("a1", "b1")
