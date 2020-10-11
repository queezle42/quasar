{-# LANGUAGE UndecidableInstances #-}

module Qd.Observable (
  SomeObservable(..),
  Observable(..),
  subscribe',
  SubscriptionHandle(..),
  RegistrationHandle(..),
  Settable(..),
  Disposable(..),
  ObservableCallback,
  ObservableState,
  ObservableMessage,
  MessageReason(..),
  ObservableVar,
  newObservableVar,
  setObservableVar,
  modifyObservableVar,
  joinObservable,
  joinObservableEither,
  FnObservable(..),
) where

import Control.Concurrent.MVar
import Control.Monad.Fix (mfix)
import Data.Binary (Binary)
import qualified Data.HashMap.Strict as HM
import Data.Unique

data MessageReason = Current | Update
  deriving (Eq, Show, Generic)
instance Binary MessageReason

type ObservableState v = Maybe v
type ObservableMessage v = (MessageReason, ObservableState v)

mapObservableMessage :: Monad m => (Maybe a -> m (Maybe b)) -> ObservableMessage a -> m (ObservableMessage b)
mapObservableMessage f (r, s) = (r, ) <$> f s

newtype SubscriptionHandle = SubscriptionHandle { unsubscribe :: IO () }
newtype RegistrationHandle = RegistrationHandle { deregister :: IO () }

class Disposable a where
  dispose :: a -> IO ()
instance Disposable SubscriptionHandle where
  dispose = unsubscribe
instance Disposable RegistrationHandle where
  dispose = deregister
instance Disposable a => Disposable (Maybe a) where
  dispose = mapM_ dispose
  
class Observable v o | o -> v where
  getValue :: o -> IO (ObservableState v)
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  mapObservable :: (ObservableState v -> ObservableState a) -> o -> SomeObservable a
  mapObservable f = mapObservableM (return . f)
  mapObservable' :: (v -> a) -> o -> SomeObservable a
  mapObservable' f = mapObservable (fmap f)
  mapObservableM :: (ObservableState v -> IO (ObservableState a)) -> o -> SomeObservable a
  mapObservableM f = SomeObservable . MappedObservable f
  mapObservableM' :: forall a. (v -> IO a) -> o -> SomeObservable a
  mapObservableM' f = mapObservableM $ mapM f

subscribe' :: Observable v o => o -> (SubscriptionHandle -> ObservableMessage v -> IO ()) -> IO SubscriptionHandle
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type ObservableCallback v = ObservableMessage v -> IO ()

instance Observable v o => Observable v (IO o) where
  getValue :: IO o -> IO (ObservableState v)
  getValue getObservable = getValue =<< getObservable
  subscribe :: IO o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe getObservable callback = do
    observable <- getObservable
    subscribe observable callback


class Settable v a where
  setValue :: a -> v -> IO ()


-- | Existential quantification wrapper for the Observable type class.
data SomeObservable v = forall o. Observable v o => SomeObservable o
instance Observable v (SomeObservable v) where
  getValue (SomeObservable o) = getValue o
  subscribe (SomeObservable o) = subscribe o
  mapObservable f (SomeObservable o) = mapObservable f o
  mapObservableM f (SomeObservable o) = mapObservableM f o
  mapObservableM' f (SomeObservable o) = mapObservableM' f o

instance Functor SomeObservable where
  fmap f = mapObservable' f


data MappedObservable b = forall a o. Observable a o => MappedObservable (ObservableState a -> IO (ObservableState b)) o
instance Observable v (MappedObservable v) where
  getValue (MappedObservable f observable) = f =<< getValue observable
  subscribe (MappedObservable f observable) callback = subscribe observable (callback <=< mapObservableMessage f)
  mapObservableM f1 (MappedObservable f2 upstream) = SomeObservable $ MappedObservable (f1 <=< f2) upstream


newtype ObservableVar v = ObservableVar (MVar (ObservableState v, HM.HashMap Unique (ObservableCallback v)))
instance Observable v (ObservableVar v) where
  getValue (ObservableVar mvar) = fst <$> readMVar mvar
  subscribe (ObservableVar mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (Current, state)
      return (state, HM.insert key callback subscribers)
    return $ SubscriptionHandle $ unsubscribe' key
    where
      unsubscribe' :: Unique -> IO ()
      unsubscribe' key = modifyMVar_ mvar $ \(state, subscribers) -> return (state, HM.delete key subscribers)

instance Settable v (ObservableVar v) where
  setValue basicObservable = setObservableVar basicObservable . Just


newObservableVar :: Maybe v -> IO (ObservableVar v)
newObservableVar defaultValue = do
  ObservableVar <$> newMVar (defaultValue, HM.empty)

setObservableVar :: ObservableVar v -> ObservableState v -> IO ()
setObservableVar (ObservableVar mvar) value = do
  modifyMVar_ mvar $ \(_, subscribers) -> do
    mapM_ (\callback -> callback (Update, value)) subscribers
    return (value, subscribers)

modifyObservableVar :: ObservableVar v -> (v -> v) -> IO ()
modifyObservableVar (ObservableVar mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    let newState = (\v -> f v) <$> oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)

newtype JoinedObservable o = JoinedObservable o
instance forall o i v. (Observable i o, Observable v i) => Observable v (JoinedObservable o) where 
  getValue :: JoinedObservable o -> IO (ObservableState v)
  getValue (JoinedObservable outer) = do
    state <- getValue outer
    case state of
      Just inner -> getValue inner
      Nothing -> return Nothing
  subscribe :: (JoinedObservable o) -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe (JoinedObservable outer) handler = do
    innerSubscriptionMVar <- newMVar dummySubscription
    outerSubscription <- subscribe outer (outerHandler innerSubscriptionMVar)
    return $ SubscriptionHandle{unsubscribe = unsubscribe outerSubscription}
      where
        dummySubscription = SubscriptionHandle { unsubscribe = return () }
        outerHandler innerSubscriptionMVar = outerHandler'
          where
            outerHandler' (_, Just inner) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              innerSubscription <- subscribe inner handler
              putMVar innerSubscriptionMVar innerSubscription
            outerHandler' (reason, Nothing) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              handler (reason, Nothing)
              putMVar innerSubscriptionMVar dummySubscription

joinObservable :: (Observable i o, Observable v i) => o -> SomeObservable v
joinObservable = SomeObservable . JoinedObservable


newtype JoinedObservableEither o = JoinedObservableEither o
instance forall e o i v. (Observable (Either e i) o, Observable v i) => Observable (Either e v) (JoinedObservableEither o) where 
  getValue :: JoinedObservableEither o -> IO (ObservableState (Either e v))
  getValue (JoinedObservableEither outer) = do
    state <- getValue outer
    case state of
      Just (Right inner) -> Right <$$> getValue inner
      Just (Left ex) -> return $ Just $ Left ex
      Nothing -> return Nothing
  subscribe :: (JoinedObservableEither o) -> (ObservableMessage (Either e v) -> IO ()) -> IO SubscriptionHandle
  subscribe (JoinedObservableEither outer) handler = do
    innerSubscriptionMVar <- newMVar dummySubscription
    outerSubscription <- subscribe outer (outerHandler innerSubscriptionMVar)
    return $ SubscriptionHandle{unsubscribe = unsubscribe outerSubscription}
      where
        dummySubscription = SubscriptionHandle { unsubscribe = return () }
        outerHandler innerSubscriptionMVar = outerHandler'
          where
            outerHandler' (_, Just (Right inner)) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              innerSubscription <- subscribe inner (handler . fmap (fmap Right))
              putMVar innerSubscriptionMVar innerSubscription
            outerHandler' (reason, Just (Left ex)) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              handler (reason, Just (Left ex))
              putMVar innerSubscriptionMVar dummySubscription
            outerHandler' (reason, Nothing) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              handler (reason, Nothing)
              putMVar innerSubscriptionMVar dummySubscription


joinObservableEither :: (Observable (Either e i) o, Observable v i) => o -> SomeObservable (Either e v)
joinObservableEither = SomeObservable . JoinedObservableEither

data FnObservable v = FnObservable {
  getValueFn :: IO (ObservableState v),
  subscribeFn :: (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
}
instance Observable v (FnObservable v) where
  getValue o = getValueFn o
  subscribe o = subscribeFn o
  mapObservableM f FnObservable{getValueFn, subscribeFn} = SomeObservable $ FnObservable {
    getValueFn = getValueFn >>= f,
    subscribeFn = \listener -> subscribeFn (mapObservableMessage f >=> listener)
  }
