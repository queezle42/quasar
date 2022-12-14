module Quasar.Observable (
  -- * Observable core
  Observable,
  ObservableState(..),
  IsRetrievable(..),
  IsObservable(..),
  observe,

  observeQ,
  observeQ_,
  observeQIO,
  observeQIO_,

  -- ** Control flow utilities
  observeWith,
  observeBlocking,
  observeAsync,

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
  ObserverCallback,

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
import Data.Unique
import Quasar.Async
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.MonadQuasar
import Quasar.Resources.Disposer

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
  -- A correct implementation of `attachObserver` must call the callback during registration. If no value is available
  -- immediately an `ObservableLoading` will be delivered. When failing due to `FailedToAttachResource` the callback
  -- may not be called.
  --
  -- The callback should return without blocking, otherwise other callbacks will be delayed. If the value can't be
  -- processed immediately, use `observeBlocking` instead or manually pass the value to a thread that processes the
  -- data.
  attachObserver :: a -> ObserverCallback r -> STMc '[] TSimpleDisposer
  attachObserver observable = attachObserver (toObservable observable)

  toObservable :: a -> Observable r
  toObservable = Observable

  mapObservable :: (r -> r2) -> a -> Observable r2
  mapObservable f = Observable . MappedObservable f . toObservable

  {-# MINIMAL toObservable | attachObserver #-}


observe
  :: (ResourceCollector m, MonadSTMc '[] m)
  => Observable a
  -> (ObservableState a -> STMc '[] ()) -- ^ callback
  -> m ()
observe observable callback = do
  disposer <- liftSTMc $ attachObserver observable callback
  collectResource disposer

observeQ
  :: (MonadQuasar m, MonadSTMc '[ThrowAny] m)
  => Observable a
  -> (ObservableState a -> STMc '[ThrowAny] ()) -- ^ callback
  -> m Disposer
observeQ observable callbackFn = do
  -- Each observer needs a dedicated scope to guarantee, that the whole observer is detached when the provided callback (or the observable implementation) fails.
  scope <- newResourceScope
  let
    sink = quasarExceptionSink scope
    wrappedCallback state = callbackFn state `catchAllSTMc` throwToExceptionSink sink
  disposer <- liftSTMc $ attachObserver observable wrappedCallback
  collectResource disposer
  pure $ toDisposer (quasarResourceManager scope)

observeQ_
    :: (MonadQuasar m, MonadSTM m)
    => Observable a
    -> (ObservableState a -> STMc '[ThrowAny] ()) -- ^ callback
    -> m ()
observeQ_ observable callback = liftQuasarSTM $ void $ observeQ observable callback

observeQIO
  :: (MonadQuasar m, MonadIO m)
  => Observable a
  -> (ObservableState a -> STMc '[ThrowAny] ()) -- ^ callback
  -> m Disposer
observeQIO observable callback = quasarAtomically $ observeQ observable callback

observeQIO_
  :: (MonadQuasar m, MonadIO m)
  => Observable a
  -> (ObservableState a -> STMc '[ThrowAny] ()) -- ^ callback
  -> m ()
observeQIO_ observable callback = quasarAtomically $ observeQ_ observable callback


type ObserverCallback a = ObservableState a -> STMc '[] ()


-- | Existential quantification wrapper for the IsObservable type class.
data Observable r = forall a. IsObservable r a => Observable a
instance IsObservable r (Observable r) where
  attachObserver (Observable o) = attachObserver o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable f

instance Applicative Observable where
  pure value = toObservable (ConstObservable (ObservableValue value))
  liftA2 fn x y = toObservable $ LiftA2Observable fn x y

instance Monad Observable where
  x >>= f = bindObservable x f

instance MonadThrow Observable where
  throwM :: forall e v. Exception e => e -> Observable v
  throwM ex = toObservable (ConstObservable (ObservableNotAvailable (toException ex)))

instance MonadCatch Observable where
  catch action handler = catchObservable action handler

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
  :: (MonadQuasar m, MonadIO m, MonadMask m)
  => Observable r
  -> (ObservableState r -> m ())
  -> m a
observeBlocking observable handler = do
  observeWith observable \fetchNext -> forever do
    msg <- atomically $ fetchNext
    handler msg

observeAsync
  :: (MonadQuasar m, MonadIO m)
  => Observable r
  -> (ObservableState r -> QuasarIO ())
  -> m (Async a)
observeAsync observable handler = async $ observeBlocking observable handler


observeWith
  :: (MonadQuasar m, MonadIO m, MonadMask m)
  => Observable r
  -> (STM (ObservableState r) -> m a)
  -> m a
observeWith observable fn = do
  var <- liftIO newEmptyTMVarIO

  bracket (aquire var) dispose
    \_ -> fn (takeTMVar var)
  where
    aquire var = observeQIO observable \msg -> do
      writeTMVar var msg


-- | Internal control flow exception for `observeWhile` and `observeWhile_`.
data ObserveWhileCompleted = ObserveWhileCompleted
  deriving stock (Eq, Show)


newtype ConstObservable a = ConstObservable (ObservableState a)
instance IsObservable a (ConstObservable a) where
  attachObserver (ConstObservable state) callback = do
    callback state
    pure mempty


data MappedObservable a = forall b. MappedObservable (b -> a) (Observable b)
instance IsObservable a (MappedObservable a) where
  attachObserver (MappedObservable fn observable) callback = attachObserver observable (callback . fmap fn)
  mapObservable f1 (MappedObservable f2 upstream) = toObservable $ MappedObservable (f1 . f2) upstream


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall a b. LiftA2Observable (a -> b -> r) (Observable a) (Observable b)

instance IsObservable a (LiftA2Observable a) where
  attachObserver (LiftA2Observable fn fx fy) callback = do
    var0 <- newTVar Nothing
    var1 <- newTVar Nothing
    let callCallback = do
          mergedValue <- runMaybeT $ liftA2 (liftA2 fn) (MaybeT (readTVar var0)) (MaybeT (readTVar var1))
          -- Run the callback only once both values have been received
          mapM_ callback mergedValue
    dx <- attachObserver fx (\update -> writeTVar var0 (Just update) >> callCallback)
    dy <- attachObserver fy (\update -> writeTVar var1 (Just update) >> callCallback)
    pure $ dx <> dy

  mapObservable f1 (LiftA2Observable f2 fx fy) = toObservable $ LiftA2Observable (\x y -> f1 (f2 x y)) fx fy


-- Implementation for bind and catch
data ObservableStep a = forall b. ObservableStep (Observable b) (ObservableState b -> Observable a)

instance IsObservable a (ObservableStep a) where
  attachObserver (ObservableStep fx fn) callback = do
    -- Callback isn't called immediately, since subscribing to fx and fn also guarantees a callback.
    rightDisposerVar <- newTVar mempty
    leftDisposer <- attachObserver fx (leftCallback rightDisposerVar)
    newUnmanagedTSimpleDisposer (disposeFn leftDisposer rightDisposerVar)
    where
      leftCallback rightDisposerVar lmsg = do
        disposeTSimpleDisposer =<< readTVar rightDisposerVar
        rightDisposer <- attachObserver (fn lmsg) callback
        writeTVar rightDisposerVar rightDisposer

      disposeFn :: TSimpleDisposer -> TVar TSimpleDisposer -> STMc '[] ()
      disposeFn leftDisposer rightDisposerVar = do
        rightDisposer <- swapTVar rightDisposerVar mempty
        disposeTSimpleDisposer (leftDisposer <> rightDisposer)

  mapObservable f (ObservableStep fx fn) = toObservable $ ObservableStep fx (f <<$>> fn)

bindObservable :: (Observable b) -> (b -> Observable a) -> Observable a
bindObservable fx fn = toObservable $ ObservableStep fx \case
  ObservableValue x -> fn x
  ObservableLoading -> toObservable (ConstObservable ObservableLoading)
  ObservableNotAvailable ex -> throwM ex

catchObservable :: Exception e => (Observable a) -> (e -> Observable a) -> Observable a
catchObservable fx fn = toObservable $ ObservableStep fx \case
  ObservableNotAvailable (fromException -> Just ex) -> fn ex
  state -> toObservable (ConstObservable state)


newtype ObserverRegistry a = ObserverRegistry (TVar (HM.HashMap Unique (ObservableState a -> STMc '[] ())))

newObserverRegistry :: STM (ObserverRegistry a)
newObserverRegistry = ObserverRegistry <$> newTVar mempty

newObserverRegistryIO :: MonadIO m => m (ObserverRegistry a)
newObserverRegistryIO = liftIO $ ObserverRegistry <$> newTVarIO mempty

registerObserver :: ObserverRegistry a -> ObserverCallback a -> ObservableState a -> STMc '[] TSimpleDisposer
registerObserver (ObserverRegistry var) callback currentState = do
  key <- newUniqueSTM
  modifyTVar var (HM.insert key callback)
  disposer <- newUnmanagedTSimpleDisposer (modifyTVar var (HM.delete key))

  liftSTMc $ callback currentState
  pure disposer

updateObservers :: ObserverRegistry a -> ObservableState a -> STMc '[] ()
updateObservers (ObserverRegistry var) newState = liftSTMc do
  mapM_ ($ newState) . HM.elems =<< readTVar var

observerRegistryHasObservers :: ObserverRegistry a -> STM Bool
observerRegistryHasObservers (ObserverRegistry var) = not . HM.null <$> readTVar var


data ObservableVar a = ObservableVar (TVar a) (ObserverRegistry a)

instance IsRetrievable a (ObservableVar a) where
  retrieve (ObservableVar var _registry) = readTVarIO var

instance IsObservable a (ObservableVar a) where
  attachObserver (ObservableVar var registry) callback =
    registerObserver registry callback . ObservableValue =<< readTVar var

newObservableVar :: MonadSTM m => a -> m (ObservableVar a)
newObservableVar x = liftSTM $ ObservableVar <$> newTVar x <*> newObserverRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newObserverRegistryIO

setObservableVar :: MonadSTM m => ObservableVar a -> a -> m ()
setObservableVar (ObservableVar var registry) newValue = liftSTMc $ do
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
  attachObserver (ObservablePrim var registry) callback = do
    registerObserver registry callback =<< readTVar var

newObservablePrim :: MonadSTM m => ObservableState a -> m (ObservablePrim a)
newObservablePrim x = liftSTM $ ObservablePrim <$> newTVar x <*> newObserverRegistry

newObservablePrimIO :: MonadIO m => ObservableState a -> m (ObservablePrim a)
newObservablePrimIO x = liftIO $ ObservablePrim <$> newTVarIO x <*> newObserverRegistryIO

setObservablePrim :: MonadSTM m => ObservablePrim a -> ObservableState a -> m ()
setObservablePrim (ObservablePrim var registry) newState = liftSTMc do
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
