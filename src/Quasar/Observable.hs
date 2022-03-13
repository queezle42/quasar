module Quasar.Observable (
  -- * Observable core types
  IsRetrievable(..),
  IsObservable(..),
  Observable(..),
  ObservableState(..),
  --toObservableUpdate,

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  setObservableVar,
  modifyObservableVar,
  stateObservableVar,

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
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.HashMap.Strict qualified as HM
import Data.Unique
import Quasar.Async
import Quasar.Future
import Quasar.Prelude
import Quasar.MonadQuasar
import Quasar.MonadQuasar.Misc
import Quasar.Resources

data ObservableState a
  = ObservableValue a
  | ObservableLoading
  | ObservableNotAvailable SomeException
  deriving stock (Show, Generic)

instance Functor ObservableState where
  fmap fn (ObservableValue x) = ObservableValue (fn x)
  fmap _ ObservableLoading = ObservableLoading
  fmap _ (ObservableNotAvailable ex) = ObservableNotAvailable ex

instance Applicative ObservableState where
  pure = ObservableValue
  liftA2 fn (ObservableValue x) (ObservableValue y) = ObservableValue (fn x y)
  liftA2 _ (ObservableNotAvailable ex) _ = ObservableNotAvailable ex
  liftA2 _ ObservableLoading _ = ObservableLoading
  liftA2 _ _ (ObservableNotAvailable ex) = ObservableNotAvailable ex
  liftA2 _ _ ObservableLoading = ObservableLoading

instance Monad ObservableState where
  (ObservableValue x) >>= fn = fn x
  ObservableLoading >>= _ = ObservableLoading
  (ObservableNotAvailable ex) >>= _ = ObservableNotAvailable ex


-- TODO rename or delete
--toObservableUpdate :: MonadThrow m => ObservableState a -> m (Maybe a)
--toObservableUpdate (ObservableValue value) = pure $ Just value
--toObservableUpdate ObservableLoading = pure Nothing
--toObservableUpdate (ObservableNotAvailable ex) = throwM ex



class IsRetrievable r a | a -> r where
  retrieve :: (MonadQuasar m, MonadIO m) => a -> m r

class IsRetrievable r a => IsObservable r a | a -> r where
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
    => a -- ^ observable
    -> ObservableCallback r -- ^ callback
    -> m ()
  observe observable = observe (toObservable observable)

  pingObservable
    :: (MonadQuasar m, MonadIO m)
    => a -- ^ observable
    -> m ()

  toObservable :: a -> Observable r
  toObservable = Observable

  mapObservable :: (r -> r2) -> a -> Observable r2
  mapObservable f = Observable . MappedObservable f

  {-# MINIMAL toObservable | observe, pingObservable #-}


type ObservableCallback v = ObservableState v -> QuasarSTM ()



-- | Existential quantification wrapper for the IsObservable type class.
data Observable r = forall a. IsObservable r a => Observable a
instance IsRetrievable r (Observable r) where
  retrieve (Observable o) = retrieve o
instance IsObservable r (Observable r) where
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
--  -> (ObservableState v -> m ())
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
--  -> (ObservableState v -> m (Maybe a))
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
--  -> (ObservableState v -> m Bool)
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


newtype ConstObservable r = ConstObservable r
instance IsRetrievable r (ConstObservable r) where
  retrieve (ConstObservable x) = pure x
instance IsObservable r (ConstObservable r) where
  observe (ConstObservable x) callback =
    ensureQuasarSTM $ callback $ ObservableValue x
  pingObservable _ = pure ()


data MappedObservable r = forall r2 a. IsObservable r2 a => MappedObservable (r2 -> r) a
instance IsRetrievable r (MappedObservable r) where
  retrieve (MappedObservable f observable) = f <$> retrieve observable
instance IsObservable r (MappedObservable r) where
  observe (MappedObservable fn observable) callback = observe observable (callback . fmap fn)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 . f2) upstream
  pingObservable (MappedObservable _ observable) = pingObservable observable


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall r0 r1. LiftA2Observable (r0 -> r1 -> r) (Observable r0) (Observable r1)

instance IsRetrievable r (LiftA2Observable r) where
  retrieve (LiftA2Observable fn fx fy) = liftQuasarIO do
    -- LATER: keep backpressure for parallel network requests
    x <- async $ retrieve fx
    y <- async $ retrieve fy
    liftA2 fn (await x) (await y)

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

  pingObservable (LiftA2Observable _ fx fy) = liftQuasarIO do
    -- LATER: keep backpressure for parallel network requests
    x <- async $ pingObservable fx
    y <- async $ pingObservable fy
    await x
    await y


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
--          (ObservableValue x) -> captureDisposable_ $ observe (fn x) (rightCallback keyVar key)
--          ObservableLoading -> noDisposable <$ callback ObservableLoading
--          (ObservableNotAvailable ex) -> noDisposable <$ callback (ObservableNotAvailable ex)
--
--        liftIO $ atomically $ putTMVar disposableVar disposable
--
--      rightCallback :: TMVar Unique -> Unique -> ObservableState r -> ResourceManagerIO ()
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
--      rightCallback :: TMVar Unique -> Unique -> ObservableState r -> ResourceManagerIO ()
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

newtype ObserverRegistry a = ObserverRegistry (TVar (HM.HashMap Unique (ObservableCallback a)))

newObserverRegistry :: STM (ObserverRegistry a)
newObserverRegistry = ObserverRegistry <$> newTVar mempty

newObserverRegistryIO :: MonadIO m => m (ObserverRegistry a)
newObserverRegistryIO = liftIO $ ObserverRegistry <$> newTVarIO mempty

registerObserver :: ObserverRegistry a -> ObservableCallback a -> ObservableState a -> QuasarSTM ()
registerObserver (ObserverRegistry var) callback currentState = do
  quasar <- askQuasar
  key <- ensureSTM newUniqueSTM
  ensureSTM $ modifyTVar var (HM.insert key (execForeignQuasarSTM quasar . callback))
  registerDisposeTransaction_ $ modifyTVar var (HM.delete key)
  callback currentState

updateObservers :: ObserverRegistry a -> ObservableState a -> QuasarSTM ()
updateObservers (ObserverRegistry var) newState =
  mapM_ ($ newState) . HM.elems =<< ensureSTM (readTVar var)


data ObservableVar a = ObservableVar (TVar a) (ObserverRegistry a)

instance IsRetrievable a (ObservableVar a) where
  retrieve (ObservableVar var _registry) = liftIO $ readTVarIO var

instance IsObservable a (ObservableVar a) where
  observe (ObservableVar var registry) callback = ensureQuasarSTM do
    registerObserver registry callback . ObservableValue =<< ensureSTM (readTVar var)

  pingObservable _ = pure ()

newObservableVar :: a -> STM (ObservableVar a)
newObservableVar x = ObservableVar <$> newTVar x <*> newObserverRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newObserverRegistryIO

setObservableVar :: MonadQuasar m => ObservableVar a -> a -> m ()
setObservableVar var = modifyObservableVar var . const

modifyObservableVar :: MonadQuasar m => ObservableVar a -> (a -> a) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar :: MonadQuasar m => ObservableVar a -> (a -> (r, a)) -> m r
stateObservableVar (ObservableVar var registry) f = undefined

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
--  observeFn :: (ObservableState v -> ResourceManagerIO ()) -> ResourceManagerIO ()
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
--  :: ((ObservableState v -> ResourceManagerIO ()) -> ResourceManagerIO ())
--  -> ResourceManagerIO (Future v)
--  -> Observable v
--fnObservable observeFn retrieveFn = toObservable FnObservable{observeFn, retrieveFn}
--
---- | Implement an Observable by directly providing functions for `retrieve` and `subscribe`.
--synchronousFnObservable
--  :: forall v.
--  ((ObservableState v -> ResourceManagerIO ()) -> ResourceManagerIO ())
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
