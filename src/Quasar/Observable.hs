module Quasar.Observable (
  ---- * Observable core types
  IsRetrievable(..),
  IsObservable(..),
  Observable(..),
  ObservableMessage(..),
  --toObservableUpdate,

  ---- * ObservableVar
  --ObservableVar,
  --newObservableVar,
  --setObservableVar,
  --modifyObservableVar,
  --stateObservableVar,

  ---- * Helper functions
  --observeWhile,
  --observeWhile_,
  --observeBlocking,
  --fnObservable,
  --synchronousFnObservable,

  ---- * Helper types
  --ObservableCallback,
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
import Quasar.Future
import Quasar.Prelude
import Quasar.MonadQuasar

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
  liftA2 fn (ObservableUpdate x) (ObservableUpdate y) = ObservableUpdate (fn x y)
  liftA2 _ (ObservableNotAvailable ex) _ = ObservableNotAvailable ex
  liftA2 _ ObservableLoading _ = ObservableLoading
  liftA2 _ _ (ObservableNotAvailable ex) = ObservableNotAvailable ex
  liftA2 _ _ ObservableLoading = ObservableLoading

instance Monad ObservableMessage where
  (ObservableUpdate x) >>= fn = fn x
  ObservableLoading >>= _ = ObservableLoading
  (ObservableNotAvailable ex) >>= _ = ObservableNotAvailable ex


-- TODO rename or delete
--toObservableUpdate :: MonadThrow m => ObservableMessage a -> m (Maybe a)
--toObservableUpdate (ObservableUpdate value) = pure $ Just value
--toObservableUpdate ObservableLoading = pure Nothing
--toObservableUpdate (ObservableNotAvailable ex) = throwM ex


class IsRetrievable v a | a -> v where
  retrieve :: (MonadQuasar m, MonadIO m) => a -> m v

class IsRetrievable v o => IsObservable v o | o -> v where
  -- | Register a callback to observe changes. The callback is called when the value changes, but depending on the
  -- delivery method (e.g. network) intermediate values may be skipped.
  --
  -- A correct implementation of observe must call the callback during registration (if no value is available
  -- immediately an `ObservableLoading` will be delivered).
  --
  -- The callback should return without blocking, otherwise other callbacks will be delayed. If the value can't be
  -- processed immediately, use `observeBlocking` instead or manually pass the value to a thread that processes the
  -- data.
  observe
    :: (MonadQuasar m)
    => o -- ^ observable
    -> ObservableCallback v -- ^ callback
    -> m ()
  observe observable = observe (toObservable observable)

  toObservable :: o -> Observable v
  toObservable = Observable

  mapObservable :: (v -> a) -> o -> Observable a
  mapObservable f = Observable . MappedObservable f

  {-# MINIMAL toObservable | observe #-}


type ObservableCallback v = ObservableMessage v -> QuasarSTM ()



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
  pure = toObservable . ConstObservable
  liftA2 fn x y = toObservable $ LiftA2Observable fn x y

--instance Monad Observable where
--  x >>= y = toObservable $ BindObservable x y
--
--instance MonadThrow Observable where
--  throwM :: forall e v. Exception e => e -> Observable v
--  throwM = toObservable . FailedObservable @v . toException
--
--instance MonadCatch Observable where
--  catch action handler = toObservable $ CatchObservable action handler
--
--instance MonadFail Observable where
--  fail = throwM . userError
--
--instance Alternative Observable where
--  empty = fail "empty"
--  x <|> y = x `catchAll` const y
--
--instance MonadPlus Observable



---- | Observe an observable by handling updates on the current thread.
----
---- `observeBlocking` will run the handler whenever the observable changes (forever / until an exception is encountered).
----
---- The handler is allowed to block. When the value changes while the handler is running the handler will be run again
---- after it completes; when the value changes multiple times it will only be executed once (with the latest value).
--observeBlocking
--  :: (IsObservable v o, MonadResourceManager m, MonadIO m, MonadMask m)
--  => o
--  -> (ObservableMessage v -> m ())
--  -> m a
--observeBlocking observable handler = do
--  -- `withScopedResourceManager` removes the `observe` callback when the `handler` fails.
--  withScopedResourceManager do
--    var <- liftIO newEmptyTMVarIO
--    observe observable \msg -> liftIO $ atomically do
--      void $ tryTakeTMVar var
--      putTMVar var msg
--
--    forever do
--      msg <- liftIO $ atomically $ takeTMVar var
--      handler msg
--
--
---- | Internal control flow exception for `observeWhile` and `observeWhile_`.
--data ObserveWhileCompleted = ObserveWhileCompleted
--  deriving stock (Eq, Show)
--
--instance Exception ObserveWhileCompleted
--
---- | Observe until the callback returns `Just`.
--observeWhile
--  :: (IsObservable v o, MonadResourceManager m, MonadIO m, MonadMask m)
--  => o
--  -> (ObservableMessage v -> m (Maybe a))
--  -> m a
--observeWhile observable callback = do
--  resultVar <- liftIO $ newIORef unreachableCodePath
--  observeWhile_ observable \msg -> do
--    callback msg >>= \case
--      Just result -> do
--        liftIO $ writeIORef resultVar result
--        pure False
--      Nothing -> pure True
--
--  liftIO $ readIORef resultVar
--
--
---- | Observe until the callback returns `False`.
--observeWhile_
--  :: (IsObservable v o, MonadResourceManager m, MonadIO m, MonadMask m)
--  => o
--  -> (ObservableMessage v -> m Bool)
--  -> m ()
--observeWhile_ observable callback =
--  catch
--    do
--      observeBlocking observable \msg -> do
--        continue <- callback msg
--        unless continue $ throwM ObserveWhileCompleted
--    \ObserveWhileCompleted -> pure ()
--
--


newtype ConstObservable v = ConstObservable v
instance IsRetrievable v (ConstObservable v) where
  retrieve (ConstObservable x) = pure x
instance IsObservable v (ConstObservable v) where
  observe (ConstObservable x) callback =
    ensureQuasarSTM $ callback $ ObservableUpdate x


data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> b) o
instance IsRetrievable v (MappedObservable v) where
  retrieve (MappedObservable f observable) = f <$> retrieve observable
instance IsObservable v (MappedObservable v) where
  observe (MappedObservable fn observable) callback = observe observable (callback . fmap fn)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 . f2) upstream


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall r0 r1. LiftA2Observable (r0 -> r1 -> r) (Observable r0) (Observable r1)

instance IsRetrievable r (LiftA2Observable r) where
  retrieve (LiftA2Observable fn fx fy) =
    liftA2 fn (retrieve fx) (retrieve fy)

instance IsObservable r (LiftA2Observable r) where
  observe (LiftA2Observable fn fx fy) callback = do
    -- TODO use alternative to ensureSTM
    var0 <- ensureSTM $ newTVar Nothing
    var1 <- ensureSTM $ newTVar Nothing
    let callCallback = do
          mergedValue <- ensureSTM $ runMaybeT $ liftA2 (liftA2 fn) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))
          -- Run the callback only once both values have been received
          mapM_ callback mergedValue
    observe fx (\update -> ensureSTM (writeTVar var0 (Just update)) >> callCallback)
    observe fy (\update -> ensureSTM (writeTVar var1 (Just update)) >> callCallback)


--data BindObservable r = forall a. BindObservable (Observable a) (a -> Observable r)
--
--instance IsRetrievable r (BindObservable r) where
--  retrieve (BindObservable fx fn) = do
--    awaitable <- retrieve fx
--    value <- liftIO $ await awaitable
--    retrieve $ fn value
--
--instance IsObservable r (BindObservable r) where
--  observe (BindObservable fx fn) callback = do
--    disposableVar <- liftIO $ newTMVarIO noDisposable
--    keyVar <- liftIO $ newTMVarIO =<< newUnique
--
--    observe fx (leftCallback disposableVar keyVar)
--    where
--      leftCallback disposableVar keyVar message = do
--        key <- liftIO newUnique
--
--        oldDisposable <- liftIO $ atomically do
--          -- Blocks while `rightCallback` is running
--          void $ swapTMVar keyVar key
--
--          takeTMVar disposableVar
--
--        disposeEventually_ oldDisposable
--
--        disposable <- case message of
--          (ObservableUpdate x) -> captureDisposable_ $ observe (fn x) (rightCallback keyVar key)
--          ObservableLoading -> noDisposable <$ callback ObservableLoading
--          (ObservableNotAvailable ex) -> noDisposable <$ callback (ObservableNotAvailable ex)
--
--        liftIO $ atomically $ putTMVar disposableVar disposable
--
--      rightCallback :: TMVar Unique -> Unique -> ObservableMessage r -> ResourceManagerIO ()
--      rightCallback keyVar key message =
--        bracket
--          -- Take key var to prevent parallel callbacks
--          (liftIO $ atomically $ takeTMVar keyVar)
--          -- Put key back
--          (liftIO . atomically . putTMVar keyVar)
--          -- Ignore all callbacks that arrive from the old `fn` when a new `fx` has been observed
--          (\currentKey -> when (key == currentKey) $ callback message)
--
--
--data CatchObservable e r = Exception e => CatchObservable (Observable r) (e -> Observable r)
--
--instance IsRetrievable r (CatchObservable e r) where
--  retrieve (CatchObservable fx fn) = retrieve fx `catch` \ex -> retrieve (fn ex)
--
--instance IsObservable r (CatchObservable e r) where
--  observe (CatchObservable fx fn) callback = do
--    disposableVar <- liftIO $ newTMVarIO noDisposable
--    keyVar <- liftIO $ newTMVarIO =<< newUnique
--
--    observe fx (leftCallback disposableVar keyVar)
--    where
--      leftCallback disposableVar keyVar message = do
--        key <- liftIO newUnique
--
--        oldDisposable <- liftIO $ atomically do
--          -- Blocks while `rightCallback` is running
--          void $ swapTMVar keyVar key
--
--          takeTMVar disposableVar
--
--        disposeEventually_ oldDisposable
--
--        disposable <- case message of
--          (ObservableNotAvailable (fromException -> Just ex)) ->
--            captureDisposable_ $ observe (fn ex) (rightCallback keyVar key)
--          msg -> noDisposable <$ callback msg
--
--        liftIO $ atomically $ putTMVar disposableVar disposable
--
--      rightCallback :: TMVar Unique -> Unique -> ObservableMessage r -> ResourceManagerIO ()
--      rightCallback keyVar key message =
--        bracket
--          -- Take key var to prevent parallel callbacks
--          (liftIO $ atomically $ takeTMVar keyVar)
--          -- Put key back
--          (liftIO . atomically . putTMVar keyVar)
--          -- Ignore all callbacks that arrive from the old `fn` when a new `fx` has been observed
--          (\currentKey -> when (key == currentKey) $ callback message)
--
--
--
--newtype ObservableVar v = ObservableVar (MVar (v, HM.HashMap Unique (ObservableCallback v)))
--instance IsRetrievable v (ObservableVar v) where
--  retrieve (ObservableVar mvar) = liftIO $ pure . fst <$> readMVar mvar
--instance IsObservable v (ObservableVar v) where
--  observe (ObservableVar mvar) callback = do
--    resourceManager <- askResourceManager
--
--    registerNewResource_ $ liftIO do
--      let wrappedCallback = enterResourceManager resourceManager . callback
--
--      key <- liftIO newUnique
--
--      modifyMVar_ mvar $ \(state, subscribers) -> do
--        -- Call listener with initial value
--        wrappedCallback (pure state)
--        pure (state, HM.insert key wrappedCallback subscribers)
--
--      atomically $ newDisposable $ disposeFn key
--    where
--      disposeFn :: Unique -> IO ()
--      disposeFn key = modifyMVar_ mvar (\(state, subscribers) -> pure (state, HM.delete key subscribers))
--
--newObservableVar :: MonadIO m => v -> m (ObservableVar v)
--newObservableVar initialValue = liftIO do
--  ObservableVar <$> newMVar (initialValue, HM.empty)
--
--setObservableVar :: MonadIO m => ObservableVar v -> v -> m ()
--setObservableVar observable value = modifyObservableVar observable (const value)
--
--stateObservableVar :: MonadIO m => ObservableVar v -> (v -> (a, v)) -> m a
--stateObservableVar (ObservableVar mvar) f =
--  liftIO $ modifyMVar mvar $ \(oldState, subscribers) -> do
--    let (result, newState) = f oldState
--    mapM_ (\callback -> callback (pure newState)) subscribers
--    pure ((newState, subscribers), result)
--
--modifyObservableVar :: MonadIO m => ObservableVar v -> (v -> v) -> m ()
--modifyObservableVar observable f = stateObservableVar observable (((), ) . f)
--
--
--
--data FnObservable v = FnObservable {
--  retrieveFn :: ResourceManagerIO (Future v),
--  observeFn :: (ObservableMessage v -> ResourceManagerIO ()) -> ResourceManagerIO ()
--}
--instance IsRetrievable v (FnObservable v) where
--  retrieve FnObservable{retrieveFn} = liftResourceManagerIO retrieveFn
--instance IsObservable v (FnObservable v) where
--  observe FnObservable{observeFn} callback = liftResourceManagerIO $ observeFn callback
--  mapObservable f FnObservable{retrieveFn, observeFn} = Observable $ FnObservable {
--    retrieveFn = f <<$>> retrieveFn,
--    observeFn = \listener -> observeFn (listener . fmap f)
--  }
--
---- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
--fnObservable
--  :: ((ObservableMessage v -> ResourceManagerIO ()) -> ResourceManagerIO ())
--  -> ResourceManagerIO (Future v)
--  -> Observable v
--fnObservable observeFn retrieveFn = toObservable FnObservable{observeFn, retrieveFn}
--
---- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
--synchronousFnObservable
--  :: forall v.
--  ((ObservableMessage v -> ResourceManagerIO ()) -> ResourceManagerIO ())
--  -> IO v
--  -> Observable v
--synchronousFnObservable observeFn synchronousRetrieveFn = fnObservable observeFn retrieveFn
--  where
--    retrieveFn :: ResourceManagerIO (Future v)
--    retrieveFn = liftIO $ pure <$> synchronousRetrieveFn


--newtype FailedObservable v = FailedObservable SomeException
--instance IsRetrievable v (FailedObservable v) where
--  retrieve (FailedObservable ex) = liftIO $ throwIO ex
--instance IsObservable v (FailedObservable v) where
--  observe (FailedObservable ex) callback = do
--    liftResourceManagerIO $ callback $ ObservableNotAvailable ex
--
--
---- TODO implement
----cacheObservable :: IsObservable v o => o -> Observable v
----cacheObservable = undefined
