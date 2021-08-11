{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable (
  -- * Observable core types
  IsRetrievable(..),
  retrieveIO,
  IsObservable(..),
  Observable(..),
  ObservableMessage(..),

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  setObservableVar,
  withObservableVar,
  modifyObservableVar,
  modifyObservableVar_,

  -- * Helper functions
  fnObservable,
  synchronousFnObservable,
  mergeObservable,
  joinObservable,
  bindObservable,
  unsafeObservableIO,

  -- * Helper types
  ObservableCallback,
) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Data.Unique
import Quasar.Awaitable
import Quasar.Core
import Quasar.Disposable
import Quasar.Prelude
import System.IO (fixIO)


data ObservableMessage a
  = ObservableUpdate a
  | ObservableConnecting
  | ObservableReconnecting SomeException
  | ObservableNotAvailable SomeException
  deriving stock (Show, Generic)

instance Functor ObservableMessage where
  fmap fn (ObservableUpdate x) = ObservableUpdate (fn x)
  fmap _ ObservableConnecting = ObservableConnecting
  fmap _ (ObservableReconnecting ex) = ObservableReconnecting ex
  fmap _ (ObservableNotAvailable ex) = ObservableNotAvailable ex

instance Applicative ObservableMessage where
  pure = ObservableUpdate
  liftA2 _ (ObservableNotAvailable ex) _ = ObservableNotAvailable ex
  liftA2 _ _ (ObservableNotAvailable ex) = ObservableNotAvailable ex
  liftA2 _ (ObservableReconnecting ex) _ = ObservableReconnecting ex
  liftA2 _ _ (ObservableReconnecting ex) = ObservableReconnecting ex
  liftA2 _ ObservableConnecting _ = ObservableConnecting
  liftA2 _ _ ObservableConnecting = ObservableConnecting
  liftA2 fn (ObservableUpdate x) (ObservableUpdate y) = ObservableUpdate (fn x y)


class IsRetrievable v a | a -> v where
  retrieve :: HasResourceManager m => a -> m (Task v)

retrieveIO :: IsRetrievable v a => a -> IO v
retrieveIO x = awaitIO =<< withDefaultResourceManager (retrieve x)

class IsRetrievable v o => IsObservable v o | o -> v where
  observe :: o -> (ObservableMessage v -> IO ()) -> IO Disposable

  toObservable :: o -> Observable v
  toObservable = Observable

  mapObservable :: (v -> a) -> o -> Observable a
  mapObservable f = Observable . MappedObservable f

-- | A variant of `observe` that passes the `Disposable` to the callback.
--
-- The disposable passed to the callback must not be used before `observeFixed` returns (otherwise an exception is thrown).
observeFixed :: IsObservable v o => o -> (Disposable -> ObservableMessage v -> IO ()) -> IO Disposable
observeFixed observable callback = fixIO $ \disposable -> observe observable (callback disposable)

type ObservableCallback v = ObservableMessage v -> IO ()


instance IsRetrievable v o => IsRetrievable v (IO o) where
  retrieve :: HasResourceManager m => IO o -> m (Task v)
  retrieve = retrieve <=< liftIO

instance IsObservable v o => IsObservable v (IO o) where
  observe :: IO o -> (ObservableMessage v -> IO ()) -> IO Disposable
  observe getObservable callback = do
    observable <- getObservable
    observe observable callback


-- | Existential quantification wrapper for the IsObservable type class.
data Observable v = forall o. IsObservable v o => Observable o
instance IsRetrievable v (Observable v) where
  retrieve (Observable o) = retrieve o
instance IsObservable v (Observable v) where
  observe (Observable o) = observe o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable f
instance Applicative Observable where
  pure = constObservable
  liftA2 = mergeObservable
instance Monad Observable where
  (>>=) = bindObservable


data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> b) o
instance IsRetrievable v (MappedObservable v) where
  retrieve (MappedObservable f observable) = f <<$>> retrieve observable
instance IsObservable v (MappedObservable v) where
  observe (MappedObservable f observable) callback = observe observable (callback . fmap f)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 . f2) upstream


newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
instance IsRetrievable v (ObservableVar v) where
  retrieve (ObservableVar mvar) = liftIO $ successfulTask . fst <$> readMVar mvar
instance IsObservable v (ObservableVar v) where
  observe (ObservableVar mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (pure state)
      pure (state, HM.insert key callback subscribers)
    pure $ synchronousDisposable (disposeFn key)
    where
      disposeFn :: Unique -> IO ()
      disposeFn key = modifyMVar_ mvar (\(state, subscribers) -> pure (state, HM.delete key subscribers))

newObservableVar :: v -> IO (ObservableVar v)
newObservableVar initialValue = do
  ObservableVar <$> newMVar (initialValue, HM.empty)

setObservableVar :: ObservableVar v -> v -> IO ()
setObservableVar (ObservableVar mvar) value = modifyMVar_ mvar $ \(_, subscribers) -> do
  mapM_ (\callback -> callback (pure value)) subscribers
  pure (value, subscribers)


modifyObservableVar :: ObservableVar v -> (v -> IO (v, a)) -> IO a
modifyObservableVar (ObservableVar mvar) f =
  modifyMVar mvar $ \(oldState, subscribers) -> do
    (newState, result) <- f oldState
    mapM_ (\callback -> callback (pure newState)) subscribers
    pure ((newState, subscribers), result)

modifyObservableVar_ :: ObservableVar v -> (v -> IO v) -> IO ()
modifyObservableVar_ (ObservableVar mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    newState <- f oldState
    mapM_ (\callback -> callback (pure newState)) subscribers
    pure (newState, subscribers)

withObservableVar :: ObservableVar v -> (v -> IO a) -> IO a
withObservableVar (ObservableVar mvar) f = withMVar mvar (f . fst)



bindObservable :: (IsObservable a ma, IsObservable b mb) => ma -> (a -> mb) -> Observable b
bindObservable x fy = joinObservable $ mapObservable fy x


-- | Internal state of `JoinedObservable`
data JoinedObservableState
  = JoinedObservableInactive
  | JoinedObservableActive Unique Disposable
  | JoinedObservableDisposed

instance IsDisposable JoinedObservableState where
  dispose JoinedObservableInactive = pure $ successfulAwaitable ()
  dispose (JoinedObservableActive _ disposable) = dispose disposable
  dispose JoinedObservableDisposed = pure $ successfulAwaitable ()

newtype JoinedObservable o = JoinedObservable o
instance forall v o i. (IsRetrievable i o, IsRetrievable v i) => IsRetrievable v (JoinedObservable o) where
  retrieve :: HasResourceManager m => JoinedObservable o -> m (Task v)
  retrieve (JoinedObservable outer) = async $ await =<< retrieve =<< await =<< retrieve outer
instance forall v o i. (IsObservable i o, IsObservable v i) => IsObservable v (JoinedObservable o) where
  observe :: JoinedObservable o -> (ObservableMessage v -> IO ()) -> IO Disposable
  observe (JoinedObservable outer) callback = do
    -- Create a resource manager to ensure all subscriptions are cleaned up when disposing.
    resourceManager <- newResourceManager unlimitedResourceManagerConfiguration

    stateMVar <- newMVar JoinedObservableInactive
    outerDisposable <- observe outer (outerCallback resourceManager stateMVar)

    attachDisposeAction_ resourceManager $ do
      d1 <- dispose outerDisposable
      d2 <- modifyMVar stateMVar $ \state -> do
        d2temp <- dispose state
        pure (JoinedObservableDisposed, d2temp)
      pure $ d1 <> d2

    pure $ toDisposable resourceManager
      where
        outerCallback :: ResourceManager -> MVar JoinedObservableState -> ObservableMessage i -> IO ()
        outerCallback resourceManager stateMVar message = do
          oldState <- takeMVar stateMVar
          disposeEventually resourceManager oldState
          key <- newUnique
          newState <- outerCallbackObserve key message
          putMVar stateMVar newState
          where
            outerCallbackObserve :: Unique -> ObservableMessage i -> IO JoinedObservableState
            outerCallbackObserve key (ObservableUpdate innerObservable) = JoinedObservableActive key <$> observe innerObservable (filteredCallback key)
            outerCallbackObserve _ ObservableConnecting = JoinedObservableInactive <$ callback ObservableConnecting
            outerCallbackObserve _ (ObservableReconnecting ex) = JoinedObservableInactive <$ callback (ObservableReconnecting ex)
            outerCallbackObserve _ (ObservableNotAvailable ex) = JoinedObservableInactive <$ callback (ObservableNotAvailable ex)
            filteredCallback :: Unique -> ObservableMessage v -> IO ()
            filteredCallback key msg =
              -- TODO write a version that does not deadlock when `observe` calls the callback directly
              undefined
              withMVar stateMVar $ \case
                JoinedObservableActive activeKey _ -> callback msg
                _ -> pure ()

joinObservable :: (IsObservable i o, IsObservable v i) => o -> Observable v
joinObservable = Observable . JoinedObservable



data MergedObservable r o0 v0 o1 v1 = MergedObservable (v0 -> v1 -> r) o0 o1
instance forall r o0 v0 o1 v1. (IsRetrievable v0 o0, IsRetrievable v1 o1) => IsRetrievable r (MergedObservable r o0 v0 o1 v1) where
  retrieve (MergedObservable merge obs0 obs1) = liftA2 (liftA2 merge) (retrieve obs0) (retrieve obs1)
instance forall r o0 v0 o1 v1. (IsObservable v0 o0, IsObservable v1 o1) => IsObservable r (MergedObservable r o0 v0 o1 v1) where
  observe (MergedObservable merge obs0 obs1) callback = do
    var0 <- newTVarIO Nothing
    var1 <- newTVarIO Nothing
    d0 <- observe obs0 (mergeCallback var0 var1 . writeTVar var0 . Just)
    d1 <- observe obs1 (mergeCallback var0 var1 . writeTVar var1 . Just)
    pure $ mconcat [d0, d1]
    where
      mergeCallback :: TVar (Maybe (ObservableMessage v0)) -> TVar (Maybe (ObservableMessage v1)) -> STM () -> IO ()
      mergeCallback var0 var1 update = do
        mMerged <- atomically $ do
          update
          runMaybeT $ liftA2 (liftA2 merge) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))

        -- Run the callback only once both values have been received
        mapM_ callback mMerged


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
mergeObservable :: (IsObservable v0 o0, IsObservable v1 o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable r
mergeObservable merge x y = Observable $ MergedObservable merge x y

data FnObservable v = FnObservable {
  retrieveFn :: forall m. HasResourceManager m => m (Task v),
  observeFn :: (ObservableMessage v -> IO ()) -> IO Disposable
}
instance IsRetrievable v (FnObservable v) where
  retrieve o = retrieveFn o
instance IsObservable v (FnObservable v) where
  observe o = observeFn o
  mapObservable f FnObservable{retrieveFn, observeFn} = Observable $ FnObservable {
    retrieveFn = f <<$>> retrieveFn,
    observeFn = \listener -> observeFn (listener . fmap f)
  }

-- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
fnObservable
  :: ((ObservableMessage v -> IO ()) -> IO Disposable)
  -> (forall m. HasResourceManager m => m (Task v))
  -> Observable v
fnObservable observeFn retrieveFn = toObservable FnObservable{observeFn, retrieveFn}

-- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
synchronousFnObservable
  :: forall v. ((ObservableMessage v -> IO ()) -> IO Disposable)
  -> IO v
  -> Observable v
synchronousFnObservable observeFn synchronousRetrieveFn = fnObservable observeFn retrieveFn
  where
    retrieveFn :: (forall m. HasResourceManager m => m (Task v))
    retrieveFn = liftIO $ successfulTask <$> synchronousRetrieveFn


newtype ConstObservable v = ConstObservable v
instance IsRetrievable v (ConstObservable v) where
  retrieve (ConstObservable x) = pure $ pure x
instance IsObservable a (ConstObservable a) where
  observe (ConstObservable x) callback = do
    callback $ ObservableUpdate x
    pure noDisposable

-- | Create an observable that contains a constant value.
constObservable :: v -> Observable v
constObservable = Observable . ConstObservable


-- | Create an observable by simply running an IO action whenever a value is requested or a callback is registered.
--
-- There is no mechanism to send more than one update, so the resulting `Observable` will only be correct in specific
-- situations.
unsafeObservableIO :: forall v. IO v -> Observable v
unsafeObservableIO action = synchronousFnObservable observeFn action
  where
    observeFn :: (ObservableMessage v -> IO ()) -> IO Disposable
    observeFn callback = do
      callback ObservableLoading
      value <- (ObservableUpdate <$> action) `catchAll` (pure . ObservableNotAvailable @v)
      callback value
      pure noDisposable


-- TODO implement
--cacheObservable :: IsObservable v o => o -> Observable v
--cacheObservable = undefined
