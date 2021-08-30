{-# LANGUAGE ViewPatterns #-}

module Quasar.Observable (
  -- * Observable core types
  IsRetrievable(..),
  retrieveIO,
  MonadObserve,
  IsObservable(..),
  Observable(..),
  ObservableMessage(..),
  toObservableUpdate,
  asyncObserve,
  asyncObserve_,

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  setObservableVar,
  withObservableVar,
  modifyObservableVar,
  modifyObservableVar_,

  -- * Helper functions
  observeWhile,
  observeWhile_,
  fnObservable,
  synchronousFnObservable,
  mergeObservable,
  joinObservable,
  bindObservable,
  unsafeObservableIO,

  -- * Helper types
  ObservableCallback,
) where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Data.Unique
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


data ObservableMessage a
  = ObservableUpdate a
  | ObservableLoading
  | ObservableNotAvailable SomeException
  deriving stock (Show, Generic)

instance Functor ObservableMessage where
  fmap fn (ObservableUpdate x) = ObservableUpdate (fn x)
  fmap _ ObservableLoading = ObservableLoading
  fmap _ (ObservableNotAvailable ex) = ObservableNotAvailable ex

instance Applicative ObservableMessage where
  pure = ObservableUpdate
  liftA2 _ (ObservableNotAvailable ex) _ = ObservableNotAvailable ex
  liftA2 _ _ (ObservableNotAvailable ex) = ObservableNotAvailable ex
  liftA2 _ ObservableLoading _ = ObservableLoading
  liftA2 _ _ ObservableLoading = ObservableLoading
  liftA2 fn (ObservableUpdate x) (ObservableUpdate y) = ObservableUpdate (fn x y)


toObservableUpdate :: MonadThrow m => ObservableMessage a -> m (Maybe a)
toObservableUpdate (ObservableUpdate value) = pure $ Just value
toObservableUpdate ObservableLoading = pure Nothing
toObservableUpdate (ObservableNotAvailable ex) = throwM ex


class IsRetrievable v a | a -> v where
  retrieve :: MonadAsync m => a -> m (Task v)

retrieveIO :: IsRetrievable v a => a -> IO v
retrieveIO x = withOnResourceManager $ await =<< retrieve x

type MonadObserve m = (MonadAwait m, MonadResourceManager m)

{-# DEPRECATED unsafeAsyncObserveIO "Old implementation of `observe`." #-}
class IsRetrievable v o => IsObservable v o | o -> v where
  observe :: MonadObserve m => o -> (ObservableMessage v -> m ()) -> m a
  observe observable callback = do
    msgVar <- liftIO $ newTVarIO ObservableLoading
    idVar <- liftIO $ newTVarIO (0 :: Word64)
    calledIdVar <- liftIO $ newTVarIO (0 :: Word64)

    bracketOnError
      do
        liftIO $ unsafeAsyncObserveIO observable \msg -> do
          currentMessage <- atomically do
            writeTVar msgVar msg
            stateTVar idVar (dup . (+ 1))
          -- Wait for `callback` to complete
          atomically do
            readTVar calledIdVar >>= \called ->
              unless (called >= currentMessage) retry
      do disposeAndAwait
      do
        const $ forever do
          (msgId, msg) <- liftIO $ atomically $ liftA2 (,) (readTVar idVar) (readTVar msgVar)
          callback msg
          liftIO $ atomically $ writeTVar calledIdVar msgId

  unsafeAsyncObserveIO :: o -> (ObservableMessage v -> IO ()) -> IO Disposable
  unsafeAsyncObserveIO observable callback = do
    resourceManager <- unsafeNewResourceManager
    onResourceManager resourceManager do
      asyncObserve_ observable (liftIO . callback)

    pure (toDisposable resourceManager)

  toObservable :: o -> Observable v
  toObservable = Observable

  mapObservable :: (v -> a) -> o -> Observable a
  mapObservable f = Observable . MappedObservable f

  {-# MINIMAL observe | unsafeAsyncObserveIO #-}


asyncObserve :: IsObservable v o => MonadAsync m => o -> (ObservableMessage v -> m ()) -> m Disposable
asyncObserve observable callback = toDisposable <$> async (observe observable callback)

asyncObserve_ :: IsObservable v o => MonadAsync m => o -> (ObservableMessage v -> m ()) -> m ()
asyncObserve_ observable callback = async_ (observe observable callback)


data ObserveWhileCompleted = ObserveWhileCompleted
  deriving stock (Eq, Show)

instance Exception ObserveWhileCompleted

-- | Observe until the callback returns `Just`.
observeWhile :: (IsObservable v o, MonadObserve m) => o -> (ObservableMessage v -> m (Maybe a)) -> m a
observeWhile observable callback = do
  resultVar <- liftIO $ newIORef impossibleCodePath
  observeWhile_ observable \msg -> do
    callback msg >>= \case
      Just result -> do
        liftIO $ writeIORef resultVar result
        pure False
      Nothing -> pure True

  liftIO $ readIORef resultVar


-- | Observe until the callback returns `False`.
observeWhile_ :: (IsObservable v o, MonadObserve m) => o -> (ObservableMessage v -> m Bool) -> m ()
observeWhile_ observable callback =
  catch
    do
      observe observable \msg -> do
        continue <- callback msg
        unless continue $ throwM ObserveWhileCompleted
    \ObserveWhileCompleted -> pure ()


type ObservableCallback v = ObservableMessage v -> IO ()


-- | Existential quantification wrapper for the IsObservable type class.
data Observable v = forall o. IsObservable v o => Observable o
instance IsRetrievable v (Observable v) where
  retrieve (Observable o) = retrieve o
instance IsObservable v (Observable v) where
  observe (Observable o) = observe o
  unsafeAsyncObserveIO (Observable o) = unsafeAsyncObserveIO o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable f

instance Applicative Observable where
  pure = toObservable . ConstObservable
  liftA2 fn x y = toObservable $ MergedObservable fn x y

instance Monad Observable where
  x >>= y = toObservable $ BindObservable x y

instance MonadThrow Observable where
  throwM :: forall e v. Exception e => e -> Observable v
  throwM = toObservable . FailedObservable @v . toException

instance MonadCatch Observable where
  catch action handler = toObservable $ CatchObservable action handler

instance MonadFail Observable where
  fail = throwM . userError

instance Alternative Observable where
  empty = fail "empty"
  x <|> y = x `catchAll` const y

instance MonadPlus Observable



data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> b) o
instance IsRetrievable v (MappedObservable v) where
  retrieve (MappedObservable f observable) = f <<$>> retrieve observable
instance IsObservable v (MappedObservable v) where
  observe (MappedObservable f observable) callback = observe observable (callback . fmap f)
  unsafeAsyncObserveIO (MappedObservable f observable) callback = unsafeAsyncObserveIO observable (callback . fmap f)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 . f2) upstream



data BindObservable r = forall a. BindObservable (Observable a) (a -> Observable r)

instance IsRetrievable r (BindObservable r) where
  retrieve (BindObservable fx fn) = async $ do
    x <- awaitResult $ retrieve fx
    awaitResult $ retrieve $ fn x

instance IsObservable r (BindObservable r) where
  unsafeAsyncObserveIO :: BindObservable r -> (ObservableMessage r -> IO ()) -> IO Disposable
  unsafeAsyncObserveIO (BindObservable fx fn) callback = do
    -- Create a resource manager to ensure all subscriptions are cleaned up when disposing.
    resourceManager <- unsafeNewResourceManager

    isDisposingVar <- newTVarIO False
    disposableVar <- newTMVarIO noDisposable
    keyVar <- newTMVarIO Nothing

    leftDisposable <- unsafeAsyncObserveIO fx (outerCallback resourceManager isDisposingVar disposableVar keyVar)

    attachDisposeAction_ resourceManager $ do
      atomically $ writeTVar isDisposingVar True
      d1 <- dispose leftDisposable
      -- Block while the `outerCallback` is running
      d2 <- dispose =<< atomically (takeTMVar disposableVar)
      pure (d1 <> d2)

    pure $ toDisposable resourceManager
    where
      outerCallback resourceManager isDisposingVar disposableVar keyVar observableMessage = mask $ \unmask -> do
        key <- newUnique

        join $ atomically $ do
          readTVar isDisposingVar >>= \case
            False -> do
              -- Blocks while an inner callback is running
              void $ swapTMVar keyVar (Just key)

              oldDisposable <- takeTMVar disposableVar

              -- IO action that will run after the STM transaction
              pure $ do
                disposeEventually resourceManager oldDisposable

                disposable <-
                  unmask (outerMessageHandler key observableMessage)
                    `onException`
                      atomically (putTMVar disposableVar noDisposable)

                atomically $ putTMVar disposableVar disposable

            -- When already disposing no new handlers should be registered
            True -> pure $ pure ()

        where
          outerMessageHandler key (ObservableUpdate x) = unsafeAsyncObserveIO (fn x) (innerCallback key)
          outerMessageHandler _ ObservableLoading = noDisposable <$ callback ObservableLoading
          outerMessageHandler _ (ObservableNotAvailable ex) = noDisposable <$ callback (ObservableNotAvailable ex)

          innerCallback :: Unique -> ObservableMessage r -> IO ()
          innerCallback key x = do
            bracket
              -- Take key var to prevent parallel callbacks
              (atomically $ takeTMVar keyVar)
              -- Put key back
              (atomically . putTMVar keyVar)
              -- Call callback when key is still valid
              (\currentKey -> when (Just key == currentKey) $ callback x)


data CatchObservable e r = Exception e => CatchObservable (Observable r) (e -> Observable r)

instance IsRetrievable r (CatchObservable e r) where
  retrieve (CatchObservable fx fn) = async $
    awaitResult (retrieve fx) `catch` \ex -> awaitResult (retrieve (fn ex))

instance IsObservable r (CatchObservable e r) where
  unsafeAsyncObserveIO :: CatchObservable e r -> (ObservableMessage r -> IO ()) -> IO Disposable
  unsafeAsyncObserveIO (CatchObservable fx fn) callback = do
    -- Create a resource manager to ensure all subscriptions are cleaned up when disposing.
    resourceManager <- unsafeNewResourceManager

    isDisposingVar <- newTVarIO False
    disposableVar <- newTMVarIO noDisposable
    keyVar <- newTMVarIO Nothing

    leftDisposable <- unsafeAsyncObserveIO fx (outerCallback resourceManager isDisposingVar disposableVar keyVar)

    attachDisposeAction_ resourceManager $ do
      atomically $ writeTVar isDisposingVar True
      d1 <- dispose leftDisposable
      -- Block while the `outerCallback` is running
      d2 <- dispose =<< atomically (takeTMVar disposableVar)
      pure (d1 <> d2)

    pure $ toDisposable resourceManager
    where
      outerCallback resourceManager isDisposingVar disposableVar keyVar observableMessage = mask $ \unmask -> do
        key <- newUnique

        join $ atomically $ do
          readTVar isDisposingVar >>= \case
            False -> do
              -- Blocks while an inner callback is running
              void $ swapTMVar keyVar (Just key)

              oldDisposable <- takeTMVar disposableVar

              -- IO action that will run after the STM transaction
              pure $ do
                disposeEventually resourceManager oldDisposable

                disposable <-
                  unmask (outerMessageHandler key observableMessage)
                    `onException`
                      atomically (putTMVar disposableVar noDisposable)

                atomically $ putTMVar disposableVar disposable

            -- When already disposing no new handlers should be registered
            True -> pure $ pure ()

        where
          outerMessageHandler key (ObservableNotAvailable (fromException -> Just ex)) = unsafeAsyncObserveIO (fn ex) (innerCallback key)
          outerMessageHandler _ msg = noDisposable <$ callback msg

          innerCallback :: Unique -> ObservableMessage r -> IO ()
          innerCallback key x = do
            bracket
              -- Take key var to prevent parallel callbacks
              (atomically $ takeTMVar keyVar)
              -- Put key back
              (atomically . putTMVar keyVar)
              -- Call callback when key is still valid
              (\currentKey -> when (Just key == currentKey) $ callback x)



newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
instance IsRetrievable v (ObservableVar v) where
  retrieve (ObservableVar mvar) = liftIO $ successfulTask . fst <$> readMVar mvar
instance IsObservable v (ObservableVar v) where
  unsafeAsyncObserveIO (ObservableVar mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (pure state)
      pure (state, HM.insert key callback subscribers)
    synchronousDisposable (disposeFn key)
    where
      disposeFn :: Unique -> IO ()
      disposeFn key = modifyMVar_ mvar (\(state, subscribers) -> pure (state, HM.delete key subscribers))

newObservableVar :: v -> IO (ObservableVar v)
newObservableVar initialValue = do
  ObservableVar <$> newMVar (initialValue, HM.empty)

setObservableVar :: MonadIO m => ObservableVar v -> v -> m ()
setObservableVar (ObservableVar mvar) value = liftIO $ modifyMVar_ mvar $ \(_, subscribers) -> do
  mapM_ (\callback -> callback (pure value)) subscribers
  pure (value, subscribers)


-- TODO change inner monad to `m` after reimplementing ObservableVar
modifyObservableVar :: MonadIO m => ObservableVar v -> (v -> IO (v, a)) -> m a
modifyObservableVar (ObservableVar mvar) f =
  liftIO $ modifyMVar mvar $ \(oldState, subscribers) -> do
    (newState, result) <- f oldState
    mapM_ (\callback -> callback (pure newState)) subscribers
    pure ((newState, subscribers), result)

-- TODO change inner monad to `m` after reimplementing ObservableVar
modifyObservableVar_ :: MonadIO m => ObservableVar v -> (v -> IO v) -> m ()
modifyObservableVar_ (ObservableVar mvar) f =
  liftIO $ modifyMVar_ mvar $ \(oldState, subscribers) -> do
    newState <- f oldState
    mapM_ (\callback -> callback (pure newState)) subscribers
    pure (newState, subscribers)

-- TODO change inner monad to `m` after reimplementing ObservableVar
withObservableVar :: MonadIO m => ObservableVar v -> (v -> IO a) -> m a
withObservableVar (ObservableVar mvar) f = liftIO $ withMVar mvar (f . fst)



bindObservable :: (IsObservable a ma, IsObservable b mb) => ma -> (a -> mb) -> Observable b
bindObservable fx fn = (toObservable fx) >>= \x -> toObservable (fn x)

joinObservable :: (IsObservable i o, IsObservable v i) => o -> Observable v
joinObservable = join . fmap toObservable . toObservable


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data MergedObservable r o0 v0 o1 v1 = MergedObservable (v0 -> v1 -> r) o0 o1
instance forall r o0 v0 o1 v1. (IsRetrievable v0 o0, IsRetrievable v1 o1) => IsRetrievable r (MergedObservable r o0 v0 o1 v1) where
  retrieve (MergedObservable merge obs0 obs1) = liftA2 (liftA2 merge) (retrieve obs0) (retrieve obs1)
instance forall r o0 v0 o1 v1. (IsObservable v0 o0, IsObservable v1 o1) => IsObservable r (MergedObservable r o0 v0 o1 v1) where
  unsafeAsyncObserveIO (MergedObservable merge obs0 obs1) callback = do
    var0 <- newTVarIO Nothing
    var1 <- newTVarIO Nothing
    d0 <- unsafeAsyncObserveIO obs0 (mergeCallback var0 var1 . writeTVar var0 . Just)
    d1 <- unsafeAsyncObserveIO obs1 (mergeCallback var0 var1 . writeTVar var1 . Just)
    pure $ mconcat [d0, d1]
    where
      mergeCallback :: TVar (Maybe (ObservableMessage v0)) -> TVar (Maybe (ObservableMessage v1)) -> STM () -> IO ()
      mergeCallback var0 var1 update = do
        mMerged <- atomically $ do
          update
          runMaybeT $ liftA2 (liftA2 merge) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))

        -- Run the callback only once both values have been received
        mapM_ callback mMerged


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- Behaves like `liftA2` on `Observable` but accepts anything that implements `IsObservable`..
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
mergeObservable :: (IsObservable v0 o0, IsObservable v1 o1) => (v0 -> v1 -> r) -> o0 -> o1 -> Observable r
mergeObservable merge x y = Observable $ MergedObservable merge x y

data FnObservable v = FnObservable {
  retrieveFn :: forall m. MonadAsync m => m (Task v),
  observeFn :: (ObservableMessage v -> IO ()) -> IO Disposable
}
instance IsRetrievable v (FnObservable v) where
  retrieve o = retrieveFn o
instance IsObservable v (FnObservable v) where
  unsafeAsyncObserveIO o = observeFn o
  mapObservable f FnObservable{retrieveFn, observeFn} = Observable $ FnObservable {
    retrieveFn = f <<$>> retrieveFn,
    observeFn = \listener -> observeFn (listener . fmap f)
  }

-- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
fnObservable
  :: ((ObservableMessage v -> IO ()) -> IO Disposable)
  -> (forall m. MonadAsync m => m (Task v))
  -> Observable v
fnObservable observeFn retrieveFn = toObservable FnObservable{observeFn, retrieveFn}

-- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
synchronousFnObservable
  :: forall v. ((ObservableMessage v -> IO ()) -> IO Disposable)
  -> IO v
  -> Observable v
synchronousFnObservable observeFn synchronousRetrieveFn = fnObservable observeFn retrieveFn
  where
    retrieveFn :: (forall m. MonadAsync m => m (Task v))
    retrieveFn = liftIO $ successfulTask <$> synchronousRetrieveFn


newtype ConstObservable v = ConstObservable v
instance IsRetrievable v (ConstObservable v) where
  retrieve (ConstObservable x) = pure $ pure x
instance IsObservable v (ConstObservable v) where
  unsafeAsyncObserveIO (ConstObservable x) callback = do
    callback $ ObservableUpdate x
    pure noDisposable


newtype FailedObservable v = FailedObservable SomeException
instance IsRetrievable v (FailedObservable v) where
  retrieve (FailedObservable ex) = liftIO $ throwIO ex
instance IsObservable v (FailedObservable v) where
  unsafeAsyncObserveIO (FailedObservable ex) callback = do
    callback $ ObservableNotAvailable ex
    pure noDisposable


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
