module Quasar.Observable.LiftSpec (spec) where

import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Prelude
import Test.Hspec

-- The following tests are compile-time tests to verify `liftObservable` can be
-- used in all desired configurations.

spec :: Spec
spec = it "compiles" True


-- Relaxing `canLoad`

test1 ::
  Observable canLoad exceptions v ->
  Observable canLoad exceptions v
test1 = liftObservable

test2 ::
  Observable canLoad exceptions v ->
  Observable Load exceptions v
test2 = liftObservable

test3 ::
  Observable NoLoad exceptions v ->
  Observable Load exceptions v
test3 = liftObservable

test4 ::
  Observable NoLoad exceptions v ->
  Observable NoLoad exceptions v
test4 = liftObservable


-- Relaxing `canLoad` while also relaxing exceptions

test5 ::
  Observable canLoad '[] v ->
  Observable canLoad exceptions v
test5 = liftObservable

test6 ::
  Observable canLoad '[] v ->
  Observable Load exceptions v
test6 = liftObservable

test7 ::
  Observable NoLoad '[] v ->
  Observable Load exceptions v
test7 = liftObservable

test8 ::
  Observable NoLoad '[] v ->
  Observable NoLoad exceptions v
test8 = liftObservable


-- Relaxing some specific exception sets

data A
  deriving Show

instance Exception A

data B
  deriving Show

instance Exception B

test9 ::
  Observable canLoad '[A] v ->
  Observable canLoad '[A, B] v
test9 = liftObservable

test10 ::
  Observable canLoad '[A] v ->
  Observable canLoad '[SomeException] v
test10 = liftObservable

test11 ::
  Observable canLoad '[A] v ->
  Observable canLoad '[B, SomeException] v
test11 = liftObservable

test12 ::
  Observable canLoad '[] v ->
  Observable canLoad '[A] v
test12 = liftObservable
