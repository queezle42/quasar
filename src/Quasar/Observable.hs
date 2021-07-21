{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable (
  Observable(..),
  IsRetrievable(..),
  retrieveIO,
  IsObservable(..),
  unsafeGetBlocking,
  subscribe',
  IsSettable(..),
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

import Control.Concurrent.MVar
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.Binary (Binary)
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Data.Unique
import Quasar.Core
import Quasar.Prelude


data MessageReason = Current | Update
  deriving stock (Eq, Show, Generic)
instance Binary MessageReason

type ObservableMessage v = (MessageReason, v)

mapObservableMessage :: (a -> b) -> ObservableMessage a -> ObservableMessage b
mapObservableMessage f (reason, x) = (reason, f x)


class IsRetrievable v a | a -> v where
  retrieve :: a -> AsyncIO v

retrieveIO :: IsRetrievable v a => a -> IO v
retrieveIO = runAsyncIO . retrieve


class IsRetrievable v o => IsObservable v o | o -> v where
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO Disposable

  toObservable :: o -> Observable v
  toObservable = Observable

  mapObservable :: (v -> a) -> o -> Observable a
  mapObservable f = Observable . MappedObservable f

-- | Variant of `retrieveIO` that throws exceptions instead of returning them.
unsafeGetBlocking :: (Exception e, IsObservable (Either e v) o) => o -> IO v
unsafeGetBlocking = either throwIO pure <=< retrieveIO

-- | A variant of `subscribe` that passes the `Disposable` to the callback.
subscribe' :: IsObservable v o => o -> (Disposable -> ObservableMessage v -> IO ()) -> IO Disposable
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type ObservableCallback v = ObservableMessage v -> IO ()


instance IsRetrievable v o => IsRetrievable v (IO o) where
  retrieve :: IO o -> AsyncIO v
  retrieve = retrieve <=< liftIO

instance IsObservable v o => IsObservable v (IO o) where
  subscribe :: IO o -> (ObservableMessage v -> IO ()) -> IO Disposable
  subscribe getObservable callback = do
    observable <- getObservable
    subscribe observable callback


class IsSettable v a | a -> v where
  setValue :: a -> v -> IO ()


-- | Existential quantification wrapper for the IsObservable type class.
data Observable v = forall o. IsObservable v o => Observable o
instance IsRetrievable v (Observable v) where
  retrieve (Observable o) = retrieve o
instance IsObservable v (Observable v) where
  subscribe (Observable o) = subscribe o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable f
  x <$ _ = constObservable x
instance Applicative Observable where
  pure = constObservable
  liftA2 = mergeObservable
  _ *> x = x
  x <* _ = x
instance Monad Observable where
  (>>=) = bindObservable


data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> b) o
instance IsRetrievable v (MappedObservable v) where
  retrieve (MappedObservable f observable) = f <$> retrieve observable
instance IsObservable v (MappedObservable v) where
  subscribe (MappedObservable f observable) callback = subscribe observable (callback . mapObservableMessage f)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 . f2) upstream


newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
instance IsRetrievable v (ObservableVar v) where
  retrieve (ObservableVar mvar) = liftIO $ fst <$> readMVar mvar
instance IsObservable v (ObservableVar v) where
  subscribe (ObservableVar mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (Current, state)
      pure (state, HM.insert key callback subscribers)
    pure $ synchronousDisposable (disposeFn key)
    where
      disposeFn :: Unique -> IO ()
      disposeFn key = modifyMVar_ mvar (\(state, subscribers) -> pure (state, HM.delete key subscribers))

instance IsSettable v (ObservableVar v) where
  setValue (ObservableVar mvar) value = modifyMVar_ mvar $ \(_, subscribers) -> do
    mapM_ (\callback -> callback (Update, value)) subscribers
    pure (value, subscribers)


newObservableVar :: v -> IO (ObservableVar v)
newObservableVar initialValue = do
  ObservableVar <$> newMVar (initialValue, HM.empty)


modifyObservableVar :: ObservableVar v -> (v -> IO (v, a)) -> IO a
modifyObservableVar (ObservableVar mvar) f =
  modifyMVar mvar $ \(oldState, subscribers) -> do
    (newState, result) <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    pure ((newState, subscribers), result)

modifyObservableVar_ :: ObservableVar v -> (v -> IO v) -> IO ()
modifyObservableVar_ (ObservableVar mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    newState <- f oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    pure (newState, subscribers)

withObservableVar :: ObservableVar a -> (a -> IO b) -> IO b
withObservableVar (ObservableVar mvar) f = withMVar mvar (f . fst)



bindObservable :: (IsObservable a ma, IsObservable b mb) => ma -> (a -> mb) -> Observable b
bindObservable x fy = joinObservable $ mapObservable fy x


newtype JoinedObservable o = JoinedObservable o
instance forall o i v. (IsRetrievable i o, IsRetrievable v i) => IsRetrievable v (JoinedObservable o) where
  retrieve :: JoinedObservable o -> AsyncIO v
  retrieve (JoinedObservable outer) = retrieve =<< retrieve outer
instance forall o i v. (IsObservable i o, IsObservable v i) => IsObservable v (JoinedObservable o) where
  subscribe :: (JoinedObservable o) -> (ObservableMessage v -> IO ()) -> IO Disposable
  subscribe (JoinedObservable outer) callback = do
    -- TODO: rewrite with latest semantics
    -- the current implementation blocks the callback while `dispose` is running
    innerDisposableMVar <- newMVar noDisposable
    outerDisposable <- subscribe outer (outerCallback innerDisposableMVar)
    pure $ mkDisposable $ do
      dispose outerDisposable
      dispose =<< liftIO (readMVar innerDisposableMVar)
      where
        outerCallback :: MVar Disposable -> ObservableMessage i -> IO ()
        outerCallback innerDisposableMVar (_reason, innerObservable) = do
          oldInnerSubscription <- takeMVar innerDisposableMVar
          void $ async $ do
            dispose oldInnerSubscription
            liftIO $ do
              newInnerSubscription <- subscribe innerObservable callback
              putMVar innerDisposableMVar newInnerSubscription

joinObservable :: (IsObservable i o, IsObservable v i) => o -> Observable v
joinObservable = Observable . JoinedObservable


joinObservableMaybe :: forall o i v. (IsObservable (Maybe i) o, IsObservable v i) => o -> Observable (Maybe v)
joinObservableMaybe = runMaybeT . join . fmap (MaybeT . fmap Just . toObservable) . MaybeT . toObservable

joinObservableMaybe' :: (IsObservable (Maybe i) o, IsObservable (Maybe v) i) => o -> Observable (Maybe v)
joinObservableMaybe' = runMaybeT . join . fmap (MaybeT . toObservable) . MaybeT . toObservable


joinObservableEither :: (IsObservable (Either e i) o, IsObservable v i) => o -> Observable (Either e v)
joinObservableEither = runExceptT . join . fmap (ExceptT . fmap Right . toObservable) . ExceptT . toObservable

joinObservableEither' :: (IsObservable (Either e i) o, IsObservable (Either e v) i) => o -> Observable (Either e v)
joinObservableEither' = runExceptT . join . fmap (ExceptT . toObservable) . ExceptT . toObservable


data MergedObservable o0 v0 o1 v1 r = MergedObservable (v0 -> v1 -> r) o0 o1
instance forall o0 v0 o1 v1 r. (IsRetrievable v0 o0, IsRetrievable v1 o1) => IsRetrievable r (MergedObservable o0 v0 o1 v1 r) where
  retrieve (MergedObservable merge obs0 obs1) = merge <$> retrieve obs0 <*> retrieve obs1
instance forall o0 v0 o1 v1 r. (IsObservable v0 o0, IsObservable v1 o1) => IsObservable r (MergedObservable o0 v0 o1 v1 r) where
  subscribe (MergedObservable merge obs0 obs1) callback = do
    currentValuesTupleRef <- newIORef (Nothing, Nothing)
    sub0 <- subscribe obs0 (mergeCallback currentValuesTupleRef . fmap Left)
    sub1 <- subscribe obs1 (mergeCallback currentValuesTupleRef . fmap Right)
    pure $ mconcat [sub0, sub1]
    where
      mergeCallback :: IORef (Maybe v0, Maybe v1) -> (MessageReason, Either v0 v1) -> IO ()
      mergeCallback currentValuesTupleRef (reason, state) = do
        currentTuple <- atomicModifyIORef' currentValuesTupleRef ((\x -> (x, x)) . updateTuple state)
        case currentTuple of
          (Just l, Just r) -> callback (reason, uncurry merge (l, r))
          _ -> pure () -- Start only once both values have been received
      updateTuple :: Either v0 v1 -> (Maybe v0, Maybe v1) -> (Maybe v0, Maybe v1)
      updateTuple (Left l) (_, r) = (Just l, r)
      updateTuple (Right r) (l, _) = (l, Just r)


-- | Merge two observables using a given merge function. Whenever the value of one of the inputs changes, the resulting observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
mergeObservable :: (IsObservable v0 o0, IsObservable v1 o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable r
mergeObservable merge x y = Observable $ MergedObservable merge x y

-- | Similar to `mergeObservable`, but built to operator on `Maybe` values: If either input value is `Nothing`, the resulting value will be `Nothing`.
mergeObservableMaybe :: (IsObservable (Maybe v0) o0, IsObservable (Maybe v1) o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable (Maybe r)
mergeObservableMaybe merge x y = Observable $ MergedObservable (liftA2 merge) x y


-- | Data type that can be used as an implementation for the `IsObservable` interface that works by directly providing functions for `retrieve` and `subscribe`.
data FnObservable v = FnObservable {
  getValueFn :: AsyncIO v,
  subscribeFn :: (ObservableMessage v -> IO ()) -> IO Disposable
}
instance IsRetrievable v (FnObservable v) where
  retrieve o = getValueFn o
instance IsObservable v (FnObservable v) where
  subscribe o = subscribeFn o
  mapObservable f FnObservable{getValueFn, subscribeFn} = Observable $ FnObservable {
    getValueFn = f <$> getValueFn,
    subscribeFn = \listener -> subscribeFn (listener . mapObservableMessage f)
  }


newtype ConstObservable a = ConstObservable a
instance IsRetrievable a (ConstObservable a) where
  retrieve (ConstObservable x) = pure x
instance IsObservable a (ConstObservable a) where
  subscribe (ConstObservable x) callback = do
    callback (Current, x)
    pure noDisposable

-- | Create an observable that contains a constant value.
constObservable :: a -> Observable a
constObservable = Observable . ConstObservable


-- TODO implement
--cacheObservable :: IsObservable v o => o -> Observable v
--cacheObservable = undefined
