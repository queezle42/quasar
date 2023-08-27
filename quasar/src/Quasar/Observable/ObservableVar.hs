{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable.ObservableVar (
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  newLoadingObservableVar,
  newLoadingObservableVarIO,
  newFailedObservableVar,
  newFailedObservableVarIO,
  writeObservableVar,
  readObservableVar,
  readObservableVarIO,
  modifyObservableVar,
  stateObservableVar,
  observableVarHasObservers,
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Observable.Core
import Quasar.Observable.Subject
import Quasar.Prelude


newtype ObservableVar canLoad exceptions a
  = ObservableVar (Subject canLoad exceptions Identity a)

deriving newtype instance IsObservableCore canLoad exceptions Identity a (ObservableVar canLoad exceptions a)
deriving newtype instance ToObservableT canLoad exceptions Identity a (ObservableVar canLoad exceptions a)


newObservableVar ::
  MonadSTMc NoRetry '[] m =>
  a -> m (ObservableVar canLoad exceptions a)
newObservableVar x = ObservableVar <$> newSubject (Identity x)

newLoadingObservableVar ::
  forall exceptions a m.
  MonadSTMc NoRetry '[] m =>
  m (ObservableVar Load exceptions a)
newLoadingObservableVar = ObservableVar <$> newLoadingSubject

newFailedObservableVar ::
  forall exceptions a e m.
  (MonadSTMc NoRetry '[] m, Exception e, e :< exceptions) =>
  e -> m (ObservableVar Load exceptions a)
newFailedObservableVar exception = ObservableVar <$> newFailedSubject exception

newObservableVarIO :: MonadIO m => a -> m (ObservableVar canLoad exceptions a)
newObservableVarIO x = ObservableVar <$> newSubjectIO (Identity x)

newLoadingObservableVarIO ::
  forall exceptions a m.
  MonadIO m =>
  m (ObservableVar Load exceptions a)
newLoadingObservableVarIO = ObservableVar <$> newLoadingSubjectIO

newFailedObservableVarIO ::
  forall exceptions a e m.
  (MonadIO m, Exception e, e :< exceptions) =>
  e -> m (ObservableVar Load exceptions a)
newFailedObservableVarIO exception =
  ObservableVar <$> newFailedSubjectIO exception

writeObservableVar :: (MonadSTMc NoRetry '[] m) => ObservableVar canLoad exceptions a -> a -> m ()
writeObservableVar (ObservableVar subject) value =
  replaceSubject subject (Identity value)

readObservableVar
  :: MonadSTMc NoRetry '[] m
  => ObservableVar NoLoad '[] a
  -> m a
readObservableVar (ObservableVar subject) = runIdentity <$> readSubject subject

readObservableVarIO
  :: MonadIO m
  => ObservableVar NoLoad '[] a
  -> m a
readObservableVarIO (ObservableVar subject) = runIdentity <$> readSubjectIO subject

modifyObservableVar :: MonadSTMc NoRetry '[] m => ObservableVar NoLoad '[] a -> (a -> a) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar
  :: MonadSTMc NoRetry '[] m
  => ObservableVar NoLoad '[] a
  -> (a -> (b, a))
  -> m b
stateObservableVar var f = liftSTMc @NoRetry @'[] do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  writeObservableVar var newValue
  pure result

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar canLoad exceptions a -> m Bool
observableVarHasObservers (ObservableVar subject) = subjectHasObservers subject
