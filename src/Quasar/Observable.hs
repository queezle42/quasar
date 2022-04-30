module Quasar.Observable (
  -- * Observable core
  Observable,
  ObservableState(..),
  IsRetrievable(..),
  IsObservable(..),
  observe_,
  observeIO,
  observeIO_,

  -- ** Control flow utilities
  observeBlocking,
  observeUntil,
  observeUntil_,

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  setObservableVar,
  modifyObservableVar,
  stateObservableVar,
  observableVarHasObservers,

  -- * Helpers

  -- ** Helper types
  ObservableCallback,

  -- ** Observable implementation primitive
  ObservablePrim,
  newObservablePrim,
  newObservablePrimIO,
  setObservablePrim,
  modifyObservablePrim,
  stateObservablePrim,
  observablePrimHasObservers,
) where

import Control.Applicative
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.HashMap.Strict qualified as HM
import Data.IORef
import Data.Unique
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


class IsRetrievable r a | a -> r where
  retrieve :: (MonadQuasar m, MonadIO m) => a -> m r

class IsObservable r a | a -> r where
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
    :: (MonadQuasar m, MonadSTM m)
    => a -- ^ observable
    -> ObservableCallback r -- ^ callback
    -> m Disposer
  observe observable = observe (toObservable observable)

  toObservable :: a -> Observable r
  toObservable = Observable

  mapObservable :: (r -> r2) -> a -> Observable r2
  mapObservable f = Observable . MappedObservable f . toObservable

  {-# MINIMAL toObservable | observe #-}


observe_
    :: (IsObservable r a, MonadQuasar m, MonadSTM m)
    => a -- ^ observable
    -> ObservableCallback r -- ^ callback
    -> m ()
observe_ observable callback = liftQuasarSTM $ void $ observe observable callback

observeIO
  :: (IsObservable r a, MonadQuasar m, MonadIO m)
  => a -- ^ observable
  -> ObservableCallback r -- ^ callback
  -> m Disposer
observeIO observable callback = quasarAtomically $ observe observable callback

observeIO_
  :: (IsObservable r a, MonadQuasar m, MonadIO m)
  => a -- ^ observable
  -> ObservableCallback r -- ^ callback
  -> m ()
observeIO_ observable callback = quasarAtomically $ observe_ observable callback


type ObservableCallback a = ObservableState a -> QuasarSTM ()


-- | Existential quantification wrapper for the IsObservable type class.
data Observable r = forall a. IsObservable r a => Observable a
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

instance Semigroup a => Semigroup (Observable a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Observable a) where
  mempty = pure mempty



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
  var <- liftIO newEmptyTMVarIO

  bracket
    do
      quasarAtomically $ observe observable \msg -> liftSTM do
        void $ tryTakeTMVar var
        putTMVar var msg
    dispose
    \_ -> forever do
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
  observe (ConstObservable x) callback = liftQuasarSTM do
    callback $ ObservableValue x
    pure trivialDisposer


newtype ThrowObservable a = ThrowObservable SomeException
instance IsRetrievable a (ThrowObservable a) where
  retrieve (ThrowObservable ex) = throwM ex
instance IsObservable a (ThrowObservable a) where
  observe (ThrowObservable ex) callback = liftQuasarSTM do
    callback $ ObservableNotAvailable ex
    pure trivialDisposer


data MappedObservable a = forall b. MappedObservable (b -> a) (Observable b)
instance IsObservable a (MappedObservable a) where
  observe (MappedObservable fn observable) callback = observe observable (callback . fmap fn)
  mapObservable f1 (MappedObservable f2 upstream) = toObservable $ MappedObservable (f1 . f2) upstream


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall a b. LiftA2Observable (a -> b -> r) (Observable a) (Observable b)

instance IsObservable a (LiftA2Observable a) where
  observe (LiftA2Observable fn fx fy) callback = liftQuasarSTM do
    var0 <- newTVar Nothing
    var1 <- newTVar Nothing
    let callCallback = do
          mergedValue <- liftSTM $ runMaybeT $ liftA2 (liftA2 fn) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))
          -- Run the callback only once both values have been received
          mapM_ callback mergedValue
    dx <- observe fx (\update -> liftSTM (writeTVar var0 (Just update)) >> callCallback)
    dy <- observe fy (\update -> liftSTM (writeTVar var1 (Just update)) >> callCallback)
    pure $ dx <> dy

  mapObservable f1 (LiftA2Observable f2 fx fy) = toObservable $ LiftA2Observable (\x y -> f1 (f2 x y)) fx fy


data BindObservable a = forall b. BindObservable (Observable b) (b -> Observable a)

instance IsObservable a (BindObservable a) where
  observe (BindObservable fx fn) callback = liftQuasarSTM do
    -- TODO Dispose in STM to remove potential extraneous (/invalid?) updates while disposing
    callback ObservableLoading
    keyVar <- newTVar =<< newUniqueSTM
    rightDisposerVar <- newTVar trivialDisposer
    leftDisposer <- observe fx (leftCallback keyVar rightDisposerVar)
    registerDisposeAction do
      dispose leftDisposer
      -- Needs to be disposed in order since there is no way to unsubscribe atomically yet
      dispose =<< readTVarIO rightDisposerVar
    where
      leftCallback keyVar rightDisposerVar lmsg = do
        disposeEventually_ =<< readTVar rightDisposerVar
        key <- newUniqueSTM
        -- Dispose is not instant, so a key is used to disarm the callback derived from the last (now outdated) value
        writeTVar keyVar key
        disposer <-
          case lmsg of
            ObservableValue x -> observe (fn x) (rightCallback key)
            ObservableLoading -> trivialDisposer <$ callback ObservableLoading
            ObservableNotAvailable ex -> trivialDisposer <$ callback (ObservableNotAvailable ex)
        writeTVar rightDisposerVar disposer
        where
          rightCallback :: Unique -> ObservableCallback a
          rightCallback callbackKey rmsg = do
            activeKey <- readTVar keyVar
            when (callbackKey == activeKey) (callback rmsg)

  mapObservable f (BindObservable fx fn) = toObservable $ BindObservable fx (f <<$>> fn)


data CatchObservable e a = Exception e => CatchObservable (Observable a) (e -> Observable a)

instance IsObservable a (CatchObservable e a) where
  observe (CatchObservable fx fn) callback = liftQuasarSTM do
    callback ObservableLoading
    keyVar <- newTVar =<< newUniqueSTM
    rightDisposerVar <- liftSTM $ newTVar trivialDisposer
    leftDisposer <- observe fx (leftCallback keyVar rightDisposerVar)
    registerDisposeAction do
      dispose leftDisposer
      -- Needs to be disposed in order since there is no way to unsubscribe atomically yet
      dispose =<< readTVarIO rightDisposerVar
    where
      leftCallback keyVar rightDisposerVar lmsg = do
        disposeEventually_ =<< readTVar rightDisposerVar
        key <- newUniqueSTM
        -- Dispose is not instant, so a key is used to disarm the callback derived from the last (now outdated) value
        writeTVar keyVar key
        disposer <-
          case lmsg of
            ObservableNotAvailable (fromException -> Just ex) -> observe (fn ex) (rightCallback key)
            _ -> trivialDisposer <$ callback lmsg
        writeTVar rightDisposerVar disposer
        where
          rightCallback :: Unique -> ObservableCallback a
          rightCallback callbackKey rmsg = do
            activeKey <- readTVar keyVar
            when (callbackKey == activeKey) (callback rmsg)


newtype ObserverRegistry a = ObserverRegistry (TVar (HM.HashMap Unique (ObservableState a -> STM ())))

newObserverRegistry :: STM (ObserverRegistry a)
newObserverRegistry = ObserverRegistry <$> newTVar mempty

newObserverRegistryIO :: MonadIO m => m (ObserverRegistry a)
newObserverRegistryIO = liftIO $ ObserverRegistry <$> newTVarIO mempty

registerObserver :: ObserverRegistry a -> ObservableCallback a -> ObservableState a -> QuasarSTM Disposer
registerObserver (ObserverRegistry var) callback currentState = do
  quasar <- askQuasar
  key <- newUniqueSTM
  modifyTVar var (HM.insert key (execForeignQuasarSTM quasar . callback))
  disposer <- registerDisposeTransaction $ modifyTVar var (HM.delete key)
  callback currentState
  pure disposer

updateObservers :: ObserverRegistry a -> ObservableState a -> STM ()
updateObservers (ObserverRegistry var) newState =
  mapM_ ($ newState) . HM.elems =<< readTVar var

observerRegistryHasObservers :: ObserverRegistry a -> STM Bool
observerRegistryHasObservers (ObserverRegistry var) = not . HM.null <$> readTVar var


data ObservableVar a = ObservableVar (TVar a) (ObserverRegistry a)

instance IsRetrievable a (ObservableVar a) where
  retrieve (ObservableVar var _registry) = liftIO $ readTVarIO var

instance IsObservable a (ObservableVar a) where
  observe (ObservableVar var registry) callback = liftQuasarSTM do
    registerObserver registry callback . ObservableValue =<< readTVar var

newObservableVar :: MonadSTM m => a -> m (ObservableVar a)
newObservableVar x = liftSTM $ ObservableVar <$> newTVar x <*> newObserverRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newObserverRegistryIO

setObservableVar :: MonadSTM m => ObservableVar a -> a -> m ()
setObservableVar (ObservableVar var registry) newValue = liftSTM do
  writeTVar var newValue
  updateObservers registry $ ObservableValue newValue

readObservableVar :: MonadSTM m => ObservableVar a -> m a
readObservableVar (ObservableVar var _) = readTVar var

modifyObservableVar :: MonadSTM m => ObservableVar a -> (a -> a) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar :: MonadSTM m => ObservableVar a -> (a -> (r, a)) -> m r
stateObservableVar var f = liftSTM do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  setObservableVar var newValue
  pure result

observableVarHasObservers :: ObservableVar a -> STM Bool
observableVarHasObservers (ObservableVar _ registry) = observerRegistryHasObservers registry


data ObservablePrim a = ObservablePrim (TVar (ObservableState a)) (ObserverRegistry a)

instance IsRetrievable a (ObservablePrim a) where
  retrieve var = atomically $
    readObservablePrim var >>= \case
      ObservableLoading -> retry
      ObservableValue value -> pure value
      ObservableNotAvailable ex -> throwM ex

instance IsObservable a (ObservablePrim a) where
  observe (ObservablePrim var registry) callback = liftQuasarSTM do
    registerObserver registry callback =<< readTVar var

newObservablePrim :: MonadSTM m => ObservableState a -> m (ObservablePrim a)
newObservablePrim x = liftSTM $ ObservablePrim <$> newTVar x <*> newObserverRegistry

newObservablePrimIO :: MonadIO m => ObservableState a -> m (ObservablePrim a)
newObservablePrimIO x = liftIO $ ObservablePrim <$> newTVarIO x <*> newObserverRegistryIO

setObservablePrim :: MonadSTM m => ObservablePrim a -> ObservableState a -> m ()
setObservablePrim (ObservablePrim var registry) newState = liftSTM do
  writeTVar var newState
  updateObservers registry $ newState

readObservablePrim :: MonadSTM m => ObservablePrim a -> m (ObservableState a)
readObservablePrim (ObservablePrim var _) = readTVar var

modifyObservablePrim :: MonadSTM m => ObservablePrim a -> (ObservableState a -> ObservableState a) -> m ()
modifyObservablePrim var f = stateObservablePrim var (((), ) . f)

stateObservablePrim :: MonadSTM m => ObservablePrim a -> (ObservableState a -> (r, ObservableState a)) -> m r
stateObservablePrim var f = liftSTM do
  oldValue <- readObservablePrim var
  let (result, newValue) = f oldValue
  setObservablePrim var newValue
  pure result

observablePrimHasObservers :: ObservablePrim a -> STM Bool
observablePrimHasObservers (ObservablePrim _ registry) = observerRegistryHasObservers registry


---- TODO implement
----cacheObservable :: IsObservable v o => o -> Observable v
----cacheObservable = undefined
