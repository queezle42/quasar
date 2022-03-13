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
  newObservableVarIO,
  setObservableVar,
  modifyObservableVar,
  stateObservableVar,

  ---- * Helper functions
  observeBlocking,
  observeUntil,
  observeUntil_,

  -- * Helper types
  ObservableCallback,
) where

import Control.Applicative
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.HashMap.Strict qualified as HM
import Data.IORef
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
  mapObservable f = Observable . MappedObservable f . toObservable

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

instance Monad Observable where
  x >>= f = toObservable $ BindObservable x f

instance MonadThrow Observable where
  throwM :: forall e v. Exception e => e -> Observable v
  throwM = toObservable . ThrowObservable @v . toException

instance MonadCatch Observable where
  catch action handler = toObservable $ CatchObservable action handler

instance MonadFail Observable where
  fail = throwM . userError

instance Alternative Observable where
  empty = fail "empty"
  x <|> y = x `catchAll` const y

instance MonadPlus Observable



-- | Observe an observable by handling updates on the current thread.
--
-- `observeBlocking` will run the handler whenever the observable changes (forever / until an exception is encountered).
--
-- The handler is allowed to block. When the value changes while the handler is running the handler will be run again
-- after it completes; when the value changes multiple times it will only be executed once (with the latest value).
observeBlocking
  :: (IsObservable r a, MonadQuasar m, MonadIO m, MonadMask m)
  => a
  -> (ObservableState r -> m ())
  -> m b
observeBlocking observable handler = do
  -- `withResourceScope` removes the `observe` callback when the `handler` fails.
  -- TODO this also releases all resources when the handler fails - is that correct? if so it should be documented
  withResourceScope do
    var <- liftIO newEmptyTMVarIO

    observe observable \msg -> liftSTM do
      void $ tryTakeTMVar var
      putTMVar var msg

    forever do
      msg <- liftIO $ atomically $ takeTMVar var
      handler msg


-- | Internal control flow exception for `observeWhile` and `observeWhile_`.
data ObserveWhileCompleted = ObserveWhileCompleted
  deriving stock (Eq, Show)

instance Exception ObserveWhileCompleted

-- | Observe until the callback returns `Just`.
observeUntil
  :: (IsObservable r a, MonadQuasar m, MonadIO m, MonadMask m)
  => a
  -> (ObservableState r -> m (Maybe b))
  -> m b
observeUntil observable callback = do
  resultVar <- liftIO $ newIORef unreachableCodePath
  observeUntil_ observable \msg -> do
    callback msg >>= \case
      Just result -> do
        liftIO $ writeIORef resultVar result
        pure False
      Nothing -> pure True

  liftIO $ readIORef resultVar


-- | Observe until the callback returns `False`.
observeUntil_
  :: (IsObservable r a, MonadQuasar m, MonadIO m, MonadMask m)
  => a
  -> (ObservableState r -> m Bool)
  -> m ()
observeUntil_ observable callback =
  catch
    do
      observeBlocking observable \msg -> do
        continue <- callback msg
        unless continue $ throwM ObserveWhileCompleted
    \ObserveWhileCompleted -> pure ()


newtype ConstObservable a = ConstObservable a
instance IsRetrievable a (ConstObservable a) where
  retrieve (ConstObservable x) = pure x
instance IsObservable a (ConstObservable a) where
  observe (ConstObservable x) callback = ensureQuasarSTM $
    callback $ ObservableValue x
  pingObservable _ = pure ()


newtype ThrowObservable a = ThrowObservable SomeException
instance IsRetrievable a (ThrowObservable a) where
  retrieve (ThrowObservable ex) = throwM ex
instance IsObservable a (ThrowObservable a) where
  observe (ThrowObservable ex) callback = ensureQuasarSTM $
    callback $ ObservableNotAvailable ex
  pingObservable _ = pure ()


data MappedObservable a = forall b. MappedObservable (b -> a) (Observable b)
instance IsRetrievable a (MappedObservable a) where
  retrieve (MappedObservable f observable) = f <$> retrieve observable
instance IsObservable a (MappedObservable a) where
  observe (MappedObservable fn observable) callback = observe observable (callback . fmap fn)
  pingObservable (MappedObservable _ observable) = pingObservable observable
  mapObservable f1 (MappedObservable f2 upstream) = toObservable $ MappedObservable (f1 . f2) upstream


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall a b. LiftA2Observable (a -> b -> r) (Observable a) (Observable b)

instance IsRetrievable a (LiftA2Observable a) where
  retrieve (LiftA2Observable fn fx fy) = liftQuasarIO do
    -- LATER: keep backpressure for parallel network requests
    future <- async $ retrieve fy
    liftA2 fn (retrieve fx) (await future)

instance IsObservable a (LiftA2Observable a) where
  observe (LiftA2Observable fn fx fy) callback = ensureQuasarSTM do
    var0 <- liftSTM $ newTVar Nothing
    var1 <- liftSTM $ newTVar Nothing
    let callCallback = do
          mergedValue <- liftSTM $ runMaybeT $ liftA2 (liftA2 fn) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))
          -- Run the callback only once both values have been received
          mapM_ callback mergedValue
    observe fx (\update -> liftSTM (writeTVar var0 (Just update)) >> callCallback)
    observe fy (\update -> liftSTM (writeTVar var1 (Just update)) >> callCallback)

  pingObservable (LiftA2Observable _ fx fy) = liftQuasarIO do
    -- LATER: keep backpressure for parallel network requests
    future <- async $ pingObservable fy
    pingObservable fx
    await future

  mapObservable f1 (LiftA2Observable f2 fx fy) = toObservable $ LiftA2Observable (\x y -> f1 (f2 x y)) fx fy


data BindObservable a = forall b. BindObservable (Observable b) (b -> Observable a)

instance IsRetrievable a (BindObservable a) where
  retrieve (BindObservable fx fn) = do
    x <- retrieve fx
    retrieve $ fn x

instance IsObservable a (BindObservable a) where
  observe (BindObservable fx fn) callback = ensureQuasarSTM do
    callback ObservableLoading
    keyVar <- newTVar =<< newUniqueSTM
    disposableVar <- liftSTM $ newTVar trivialDisposer
    observe fx (leftCallback keyVar disposableVar)
    where
      leftCallback keyVar disposableVar lmsg = do
        disposeEventually_ =<< readTVar disposableVar
        key <- newUniqueSTM
        -- Dispose is not instant, so a key is used to disarm the callback derived from the last (now outdated) value
        writeTVar keyVar key
        disposer <- captureResources_
          case lmsg of
            ObservableValue x -> observe (fn x) (rightCallback key)
            ObservableLoading -> callback ObservableLoading
            ObservableNotAvailable ex -> callback (ObservableNotAvailable ex)
        writeTVar disposableVar disposer
        where
          rightCallback :: Unique -> ObservableCallback a
          rightCallback callbackKey rmsg = do
            activeKey <- readTVar keyVar
            when (callbackKey == activeKey) (callback rmsg)

  pingObservable (BindObservable fx fn) = do
    x <- retrieve fx
    pingObservable (fn x)

  mapObservable f (BindObservable fx fn) = toObservable $ BindObservable fx (f <<$>> fn)


data CatchObservable e a = Exception e => CatchObservable (Observable a) (e -> Observable a)

instance IsRetrievable a (CatchObservable e a) where
  retrieve (CatchObservable fx fn) = retrieve fx `catch` \ex -> retrieve (fn ex)

instance IsObservable a (CatchObservable e a) where
  observe (CatchObservable fx fn) callback = ensureQuasarSTM do
    callback ObservableLoading
    keyVar <- newTVar =<< newUniqueSTM
    disposableVar <- liftSTM $ newTVar trivialDisposer
    observe fx (leftCallback keyVar disposableVar)
    where
      leftCallback keyVar disposableVar lmsg = do
        disposeEventually_ =<< readTVar disposableVar
        key <- newUniqueSTM
        -- Dispose is not instant, so a key is used to disarm the callback derived from the last (now outdated) value
        writeTVar keyVar key
        disposer <- captureResources_
          case lmsg of
            ObservableNotAvailable (fromException -> Just ex) -> observe (fn ex) (rightCallback key)
            _ -> callback lmsg
        writeTVar disposableVar disposer
        where
          rightCallback :: Unique -> ObservableCallback a
          rightCallback callbackKey rmsg = do
            activeKey <- readTVar keyVar
            when (callbackKey == activeKey) (callback rmsg)

  pingObservable (CatchObservable fx fn) = do
    pingObservable fx `catch` \ex -> pingObservable (fn ex)


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

newObservableVar :: MonadSTM m => a -> m (ObservableVar a)
newObservableVar x = liftSTM $ ObservableVar <$> newTVar x <*> newObserverRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newObserverRegistryIO

setObservableVar :: MonadQuasar m => ObservableVar a -> a -> m ()
setObservableVar var = modifyObservableVar var . const

modifyObservableVar :: MonadQuasar m => ObservableVar a -> (a -> a) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar :: MonadQuasar m => ObservableVar a -> (a -> (r, a)) -> m r
stateObservableVar (ObservableVar var registry) f = ensureQuasarSTM do
  (result, newValue) <- liftSTM do
    oldValue <- readTVar var
    let (result, newValue) = f oldValue
    writeTVar var newValue
    pure (result, newValue)
  updateObservers registry $ ObservableValue newValue
  pure result


---- TODO implement
----cacheObservable :: IsObservable v o => o -> Observable v
----cacheObservable = undefined
