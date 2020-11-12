{-# LANGUAGE UndecidableInstances #-}

module Qd.Observable (
  SomeObservable(..),
  Gettable(..),
  Observable(..),
  unsafeGetValue,
  subscribe',
  SubscriptionHandle(..),
  RegistrationHandle(..),
  Settable(..),
  Disposable(..),
  ObservableCallback,
  ObservableMessage,
  MessageReason(..),
  ObservableVar,
  newObservableVar,
  withObservableVar,
  modifyObservableVar,
  modifyObservableVar_,
  bindObservable,
  joinObservable,
  joinObservableMaybe,
  joinObservableMaybe',
  joinObservableEither,
  joinObservableEither',
  mergeObservable,
  mergeObservableMaybe,
  constObservable,
  FnObservable(..),
) where

import Qd.Prelude

import Control.Concurrent.MVar
import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.Binary (Binary)
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Data.Unique

data MessageReason = Current | Update
  deriving (Eq, Show, Generic)
instance Binary MessageReason

type ObservableMessage v = (MessageReason, v)

mapObservableMessage :: Monad m => (a -> m b) -> ObservableMessage a -> m (ObservableMessage b)
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


class Gettable v a | a -> v where
  getValue :: a -> IO v


class Gettable v o => Observable v o | o -> v where
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  toSomeObservable :: o -> SomeObservable v
  toSomeObservable = SomeObservable
  mapObservable :: (v -> a) -> o -> SomeObservable a
  mapObservable f = mapObservableM (return . f)
  mapObservableM :: (v -> IO a) -> o -> SomeObservable a
  mapObservableM f = SomeObservable . MappedObservable f

-- | Variant of `getValue` that throws exceptions instead of returning them.
unsafeGetValue :: (Exception e, Observable (Either e v) o) => o -> IO v
unsafeGetValue = either throw return <=< getValue

-- | A variant of `subscribe` that passes the `SubscriptionHandle` to the callback.
subscribe' :: Observable v o => o -> (SubscriptionHandle -> ObservableMessage v -> IO ()) -> IO SubscriptionHandle
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type ObservableCallback v = ObservableMessage v -> IO ()


instance Gettable v o => Gettable v (IO o) where
  getValue :: IO o -> IO v
  getValue getGettable = getValue =<< getGettable
instance Observable v o => Observable v (IO o) where
  subscribe :: IO o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe getObservable callback = do
    observable <- getObservable
    subscribe observable callback


class Settable v a | a -> v where
  setValue :: a -> v -> IO ()


-- | Existential quantification wrapper for the Observable type class.
data SomeObservable v = forall o. Observable v o => SomeObservable o
instance Gettable v (SomeObservable v) where
  getValue (SomeObservable o) = getValue o
instance Observable v (SomeObservable v) where
  subscribe (SomeObservable o) = subscribe o
  toSomeObservable = id
  mapObservable f (SomeObservable o) = mapObservable f o
  mapObservableM f (SomeObservable o) = mapObservableM f o

instance Functor SomeObservable where
  fmap f = mapObservable f
  x <$ _ = constObservable x
instance Applicative SomeObservable where
  pure = constObservable
  liftA2 = mergeObservable
  _ *> x = x
  x <* _ = x
instance Monad SomeObservable where
  (>>=) = bindObservable
  _ >> x = x


data MappedObservable b = forall a o. Observable a o => MappedObservable (a -> IO b) o
instance Gettable v (MappedObservable v) where
  getValue (MappedObservable f observable) = f =<< getValue observable
instance Observable v (MappedObservable v) where
  subscribe (MappedObservable f observable) callback = subscribe observable (callback <=< mapObservableMessage f)
  mapObservableM f1 (MappedObservable f2 upstream) = SomeObservable $ MappedObservable (f1 <=< f2) upstream


newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
instance Gettable v (ObservableVar v) where
  getValue (ObservableVar mvar) = fst <$> readMVar mvar
instance Observable v (ObservableVar v) where
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
  setValue (ObservableVar mvar) value = modifyMVar_ mvar $ \(_, subscribers) -> do
    mapM_ (\callback -> callback (Update, value)) subscribers
    return (value, subscribers)


newObservableVar :: v -> IO (ObservableVar v)
newObservableVar initialValue = do
  ObservableVar <$> newMVar (initialValue, HM.empty)


modifyObservableVar :: ObservableVar v -> (v -> IO (v, a)) -> IO a
modifyObservableVar (ObservableVar mvar) f =
  modifyMVar mvar $ \(oldState, subscribers) -> do
    (newState, result) <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return ((newState, subscribers), result)

modifyObservableVar_ :: ObservableVar v -> (v -> IO v) -> IO ()
modifyObservableVar_ (ObservableVar mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    newState <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)

withObservableVar :: ObservableVar a -> (a -> IO b) -> IO b
withObservableVar (ObservableVar mvar) f = withMVar mvar (f . fst)



bindObservable :: (Observable a ma, Observable b mb) => ma -> (a -> mb) -> SomeObservable b
bindObservable x fy = joinObservable $ mapObservable fy x


newtype JoinedObservable o = JoinedObservable o
instance forall o i v. (Gettable i o, Gettable v i) => Gettable v (JoinedObservable o) where
  getValue :: JoinedObservable o -> IO v
  getValue (JoinedObservable outer) = getValue =<< getValue outer
instance forall o i v. (Observable i o, Observable v i) => Observable v (JoinedObservable o) where
  subscribe :: (JoinedObservable o) -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  subscribe (JoinedObservable outer) callback = do
    innerSubscriptionMVar <- newMVar dummySubscription
    outerSubscription <- subscribe outer (outerCallback innerSubscriptionMVar)
    return $ SubscriptionHandle{unsubscribe = unsubscribe outerSubscription >> readMVar innerSubscriptionMVar >>= dispose}
      where
        dummySubscription = SubscriptionHandle { unsubscribe = return () }
        outerCallback innerSubscriptionMVar = outerSubscription'
          where
            outerSubscription' (_, inner) = do
              unsubscribe =<< takeMVar innerSubscriptionMVar
              innerSubscription <- subscribe inner callback
              putMVar innerSubscriptionMVar innerSubscription

joinObservable :: (Observable i o, Observable v i) => o -> SomeObservable v
joinObservable = SomeObservable . JoinedObservable


joinObservableMaybe :: forall o i v. (Observable (Maybe i) o, Observable v i) => o -> SomeObservable (Maybe v)
joinObservableMaybe = runMaybeT . join . fmap (MaybeT . fmap Just . toSomeObservable) . MaybeT . toSomeObservable

joinObservableMaybe' :: (Observable (Maybe i) o, Observable (Maybe v) i) => o -> SomeObservable (Maybe v)
joinObservableMaybe' = runMaybeT . join . fmap (MaybeT . toSomeObservable) . MaybeT . toSomeObservable


joinObservableEither :: (Observable (Either e i) o, Observable v i) => o -> SomeObservable (Either e v)
joinObservableEither = runExceptT . join . fmap (ExceptT . fmap Right . toSomeObservable) . ExceptT . toSomeObservable

joinObservableEither' :: (Observable (Either e i) o, Observable (Either e v) i) => o -> SomeObservable (Either e v)
joinObservableEither' = runExceptT . join . fmap (ExceptT . toSomeObservable) . ExceptT . toSomeObservable


data MergedObservable o0 v0 o1 v1 r = MergedObservable (v0 -> v1 -> r) o0 o1
instance forall o0 v0 o1 v1 r. (Gettable v0 o0, Gettable v1 o1) => Gettable r (MergedObservable o0 v0 o1 v1 r) where
  getValue (MergedObservable merge obs0 obs1) = do
    x0 <- getValue obs0
    x1 <- getValue obs1
    return $ merge x0 x1
instance forall o0 v0 o1 v1 r. (Observable v0 o0, Observable v1 o1) => Observable r (MergedObservable o0 v0 o1 v1 r) where
  subscribe (MergedObservable merge obs0 obs1) callback = do
    currentValuesTupleRef <- newIORef (Nothing, Nothing)
    sub0 <- subscribe obs0 (mergeCallback currentValuesTupleRef . fmap Left)
    sub1 <- subscribe obs1 (mergeCallback currentValuesTupleRef . fmap Right)
    return $ SubscriptionHandle{unsubscribe = unsubscribe sub0 >> unsubscribe sub1}
    where
      mergeCallback :: IORef (Maybe v0, Maybe v1) -> (MessageReason, Either v0 v1) -> IO ()
      mergeCallback currentValuesTupleRef (reason, state) = do
        currentTuple <- atomicModifyIORef' currentValuesTupleRef (dup . updateTuple state)
        case currentTuple of
          (Just l, Just r) -> callback (reason, uncurry merge (l, r))
          _ -> return () -- Start only once both values have been received
      updateTuple :: Either v0 v1 -> (Maybe v0, Maybe v1) -> (Maybe v0, Maybe v1)
      updateTuple (Left l) (_, r) = (Just l, r)
      updateTuple (Right r) (l, _) = (l, Just r)


-- | Merge two observables using a given merge function. Whenever the value of one of the inputs changes, the resulting observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
mergeObservable :: (Observable v0 o0, Observable v1 o1) => (v0 -> v1 -> r) -> o0 -> o1 -> SomeObservable r
mergeObservable merge x y = SomeObservable $ MergedObservable merge x y

-- | Similar to `mergeObservable`, but built to operator on `Maybe` values: If either input value is `Nothing`, the resulting value will be `Nothing`.
mergeObservableMaybe :: (Observable (Maybe v0) o0, Observable (Maybe v1) o1) => (v0 -> v1 -> r) -> o0 -> o1 -> SomeObservable (Maybe r)
mergeObservableMaybe merge x y = SomeObservable $ MergedObservable (liftA2 merge) x y


-- | Data type that can be used as an implementation for the `Observable` interface that works by directly providing functions for `getValue` and `subscribe`.
data FnObservable v = FnObservable {
  getValueFn :: IO v,
  subscribeFn :: (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
}
instance Gettable v (FnObservable v) where
  getValue o = getValueFn o
instance Observable v (FnObservable v) where
  subscribe o = subscribeFn o
  mapObservableM f FnObservable{getValueFn, subscribeFn} = SomeObservable $ FnObservable {
    getValueFn = getValueFn >>= f,
    subscribeFn = \listener -> subscribeFn (mapObservableMessage f >=> listener)
  }


newtype ConstObservable a = ConstObservable a
instance Gettable a (ConstObservable a) where
  getValue (ConstObservable x) = return x
instance Observable a (ConstObservable a) where
  subscribe (ConstObservable x) callback = do
    callback (Current, x)
    return $ SubscriptionHandle { unsubscribe = return () }
-- | Create an observable that contains a constant value.
constObservable :: a -> SomeObservable a
constObservable = SomeObservable . ConstObservable


-- TODO implement
_cacheObservable :: Observable v o => o -> SomeObservable v
_cacheObservable = SomeObservable
