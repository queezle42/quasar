module Quasar.Observable.BindSpec (spec) where

import Quasar.Observable.Core
import Quasar.Observable.ObservableVar
import Quasar.Prelude
import Quasar.Resources (dispose)
import Test.Hspec

spec :: Spec
spec = describe "Observable bind" do
  it "can be read" do
    var1 <- newObservableVarIO True
    var2 <- newObservableVarIO 21
    var3 <- newLoadingObservableVarIO

    let
      obs :: Observable Load '[] Int
      obs = toObservable var1 >>= \x -> if x then toObservable var2 else toObservable var3

    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 21))

    atomically $ writeObservableVar var1 False
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLoading

    atomically $ writeObservableVar var3 42
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 42))

  it "can change between different live observables" do
    accum <- newTVarIO []

    var1 <- newObservableVarIO True
    var2 <- newObservableVarIO 21
    var3 <- newObservableVarIO 42

    let
      obs :: Observable Load '[] Int
      obs = toObservable var1 >>= \x -> if x then toObservable var2 else toObservable var3

    (disposer, initial) <- atomicallyC $ attachObserver# obs (modifyTVar accum . (:))
    initial `shouldBe` ObservableStateLive (ObservableResultOk (Identity 21))
    readTVarIO accum `shouldReturn` []
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 21))

    atomically $ writeObservableVar var1 False
    readTVarIO accum `shouldReturn` [ObservableChangeLiveReplace (ObservableResultOk (Identity 42))]
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 42))

    dispose disposer

  it "can change to a loading observable" do
    accum <- newTVarIO []

    var1 <- newObservableVarIO True
    var2 <- newObservableVarIO 21
    var3 <- newLoadingObservableVarIO

    let
      obs :: Observable Load '[] Int
      obs = toObservable var1 >>= \x -> if x then toObservable var2 else toObservable var3

    (disposer, initial) <- atomicallyC $ attachObserver# obs (modifyTVar accum . (:))
    initial `shouldBe` ObservableStateLive (ObservableResultOk (Identity 21))
    readTVarIO accum `shouldReturn` []
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 21))

    atomically $ writeObservableVar var1 False
    readTVarIO accum `shouldReturn` [ObservableChangeLoadingClear]
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLoading

    atomically $ writeObservableVar var3 42
    readTVarIO accum `shouldReturn` [ObservableChangeLiveReplace (ObservableResultOk (Identity 42)), ObservableChangeLoadingClear]
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 42))

    dispose disposer

  it "can switch from a loading observable to a live observable" do
    accum <- newTVarIO []

    var1 <- newObservableVarIO False
    var2 <- newObservableVarIO 21

    let
      obs :: Observable Load '[] Int
      obs = toObservable var1 >>= \x -> if x then toObservable var2 else constObservable ObservableStateLoading

    (disposer, initial) <- atomicallyC $ attachObserver# obs (modifyTVar accum . (:))
    initial `shouldBe` ObservableStateLoading
    readTVarIO accum `shouldReturn` []
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLoading

    atomically $ writeObservableVar var1 True
    readTVarIO accum `shouldReturn` [ObservableChangeLiveReplace (ObservableResultOk (Identity 21))]
    atomicallyC (readObservable# obs) `shouldReturn` ObservableStateLive (ObservableResultOk (Identity 21))

    dispose disposer
