{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable (
  -- * Observable core
  Observable,
  IsObservable(..),
  ObserverCallback,
  observe,

  observeQ,
  observeQ_,
  observeQIO,
  observeQIO_,

  -- ** Control flow utilities
  observeWith,
  observeBlocking,
  observeAsync,

  -- * ObservableEx
  ObservableEx,
  IsObservableEx,
  toObservableEx,
  extendObservableEx,

  -- ** Loading state
  ObservableLoading,

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  setObservableVar,
  modifyObservableVar,
  stateObservableVar,
  observableVarHasObservers,
) where

import Control.Applicative
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Data.Coerce (coerce)
import Quasar.Async
import Quasar.Exceptions
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry

type ObserverCallback a = a -> STMc NoRetry '[] ()

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
  attachObserver :: a -> ObserverCallback r -> STMc NoRetry '[] TSimpleDisposer
  attachObserver observable = attachObserver (toObservable observable)

  readObservable :: a -> STMc NoRetry '[] r
  readObservable observable = readObservable (toObservable observable)

  toObservable :: a -> Observable r
  toObservable = Observable

  mapObservable :: (r -> r2) -> a -> Observable r2
  mapObservable f = Observable . MappedObservable f . toObservable

  {-# MINIMAL toObservable | attachObserver, readObservable #-}


observe
  :: (ResourceCollector m, MonadSTMc NoRetry '[] m)
  => Observable a
  -> (a -> STMc NoRetry '[] ()) -- ^ callback
  -> m ()
observe observable callback = do
  disposer <- liftSTMc $ attachObserver observable callback
  collectResource disposer

observeQ
  :: (MonadQuasar m, MonadSTMc NoRetry '[SomeException] m)
  => Observable a
  -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
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
    -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
    -> m ()
observeQ_ observable callback = liftQuasarSTM $ void $ observeQ observable callback

observeQIO
  :: (MonadQuasar m, MonadIO m)
  => Observable a
  -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
  -> m Disposer
observeQIO observable callback = quasarAtomically $ observeQ observable callback

observeQIO_
  :: (MonadQuasar m, MonadIO m)
  => Observable a
  -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
  -> m ()
observeQIO_ observable callback = quasarAtomically $ observeQ_ observable callback


-- | Existential quantification wrapper for the IsObservable type class.
data Observable r = forall a. IsObservable r a => Observable a
instance IsObservable r (Observable r) where
  attachObserver (Observable o) = attachObserver o
  toObservable = id
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable f

instance Applicative Observable where
  pure value = toObservable (ConstObservable value)
  liftA2 fn x y = toObservable $ LiftA2Observable fn x y

instance Monad Observable where
  x >>= f = toObservable $ BindObservable x f

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
  -> (r -> m ())
  -> m a
observeBlocking observable handler = do
  observeWith observable \fetchNext -> forever do
    msg <- atomically $ fetchNext
    handler msg

observeAsync
  :: (MonadQuasar m, MonadIO m)
  => Observable r
  -> (r -> QuasarIO ())
  -> m (Async a)
observeAsync observable handler = async $ observeBlocking observable handler


observeWith
  :: (MonadQuasar m, MonadIO m, MonadMask m)
  => Observable r
  -> (STM r -> m a)
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


newtype ConstObservable a = ConstObservable a
instance IsObservable a (ConstObservable a) where
  attachObserver (ConstObservable value) callback = do
    callback value
    pure mempty

  readObservable (ConstObservable value) = pure value


data MappedObservable a = forall b. MappedObservable (b -> a) (Observable b)
instance IsObservable a (MappedObservable a) where
  attachObserver (MappedObservable fn observable) callback = attachObserver observable (callback . fn)
  readObservable (MappedObservable fn observable) = fn <$> readObservable observable
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
          mergedValue <- runMaybeT $ liftA2 fn (MaybeT (readTVar var0)) (MaybeT (readTVar var1))
          -- Run the callback only once both values have been received
          mapM_ callback mergedValue
    dx <- attachObserver fx (\update -> writeTVar var0 (Just update) >> callCallback)
    dy <- attachObserver fy (\update -> writeTVar var1 (Just update) >> callCallback)
    pure $ dx <> dy

  readObservable (LiftA2Observable fn fx fy) =
    liftA2 fn (readObservable fx) (readObservable fy)

  mapObservable f1 (LiftA2Observable f2 fx fy) =
    toObservable $ LiftA2Observable (\x y -> f1 (f2 x y)) fx fy


data BindObservable a = forall b. BindObservable (Observable b) (b -> Observable a)

instance IsObservable a (BindObservable a) where
  attachObserver (BindObservable fx fn) callback = do
    -- Callback isn't called immediately, since subscribing to fx and fn also guarantees a callback.
    rightDisposerVar <- newTVar mempty
    leftDisposer <- attachObserver fx (leftCallback rightDisposerVar)
    newUnmanagedTSimpleDisposer (disposeFn leftDisposer rightDisposerVar)
    where
      leftCallback rightDisposerVar lmsg = do
        disposeTSimpleDisposer =<< readTVar rightDisposerVar
        rightDisposer <- attachObserver (fn lmsg) callback
        writeTVar rightDisposerVar rightDisposer

      disposeFn :: TSimpleDisposer -> TVar TSimpleDisposer -> STMc NoRetry '[] ()
      disposeFn leftDisposer rightDisposerVar = do
        rightDisposer <- swapTVar rightDisposerVar mempty
        disposeTSimpleDisposer (leftDisposer <> rightDisposer)

  readObservable (BindObservable fx fn) =
    readObservable . fn =<< readObservable fx

  mapObservable f (BindObservable fx fn) =
    toObservable $ BindObservable fx (f <<$>> fn)


data ObservableVar a = ObservableVar (TVar a) (CallbackRegistry a)

instance IsObservable a (ObservableVar a) where
  attachObserver (ObservableVar var registry) callback = do
    disposer <- registerCallback registry callback
    callback =<< readTVar var
    pure disposer

  readObservable = readObservableVar

newObservableVar :: MonadSTMc NoRetry '[] m => a -> m (ObservableVar a)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar x <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newCallbackRegistryIO

setObservableVar :: MonadSTMc NoRetry '[] m => ObservableVar a -> a -> m ()
setObservableVar (ObservableVar var registry) value = liftSTMc $ do
  writeTVar var value
  callCallbacks registry value

readObservableVar :: ObservableVar a -> STMc NoRetry '[] a
readObservableVar (ObservableVar var _) = readTVar var

modifyObservableVar :: MonadSTMc NoRetry '[] m => ObservableVar a -> (a -> a) -> m ()
modifyObservableVar var f = stateObservableVar var (((), ) . f)

stateObservableVar :: MonadSTMc NoRetry '[] m => ObservableVar a -> (a -> (r, a)) -> m r
stateObservableVar var f = liftSTMc do
  oldValue <- readObservableVar var
  let (result, newValue) = f oldValue
  setObservableVar var newValue
  pure result

observableVarHasObservers :: ObservableVar a -> STM Bool
observableVarHasObservers (ObservableVar _ registry) = callbackRegistryHasCallbacks registry


---- TODO implement
----cacheObservable :: IsObservable v o => o -> Observable v
----cacheObservable = undefined


-- * ObservableEx


type IsObservableEx exceptions a = IsObservable (Either (Ex exceptions) a)

toObservableEx :: Observable (Either (Ex exceptions) a) -> ObservableEx exceptions a
toObservableEx = ObservableEx

newtype ObservableEx exceptions a = ObservableEx (Observable (Either (Ex exceptions) a))

extendObservableEx :: sub :<< super => ObservableEx sub a -> ObservableEx super a
extendObservableEx (ObservableEx o) = ObservableEx $ coerce <$> o

instance IsObservable (Either (Ex exceptions) a) (ObservableEx exceptions a) where
  attachObserver (ObservableEx o) = attachObserver o
  readObservable (ObservableEx o) = readObservable o
  toObservable (ObservableEx o) = o
  mapObservable f (ObservableEx o) = mapObservable f o

instance Functor (ObservableEx exceptions) where
  fmap f x = ObservableEx $ mapObservable (fmap f) x

instance Applicative (ObservableEx exceptions) where
  pure value = ObservableEx $ pure (Right value)
  liftA2 fn (ObservableEx x) (ObservableEx y) =
    ObservableEx $ liftA2 (liftA2 fn) x y

instance Monad (ObservableEx exceptions) where
  (ObservableEx x) >>= f = ObservableEx $ x >>= \case
    (Left ex) -> pure (Left ex)
    Right y -> toObservable (f y)


instance (Exception e, e :< exceptions) => Throw e (ObservableEx exceptions) where
  throwC ex = ObservableEx $ pure (Left (toEx ex))

instance ThrowEx (ObservableEx exceptions) where
  unsafeThrowEx = ObservableEx . pure . Left . unsafeToEx @exceptions

instance SomeException :< exceptions => MonadThrow (ObservableEx exceptions) where
  throwM = throwC . toException

instance (SomeException :< exceptions, Exception (Ex exceptions)) => MonadCatch (ObservableEx exceptions) where
  catch (ObservableEx x) f = ObservableEx $ x >>= \case
    left@(Left ex) -> case fromException (toException ex) of
      Just matched -> toObservable (f matched)
      Nothing -> pure left
    Right y -> pure (Right y)

instance SomeException :< exceptions => MonadFail (ObservableEx exceptions) where
  fail = throwM . userError

instance (SomeException :< exceptions, Exception (Ex exceptions)) => Alternative (ObservableEx exceptions) where
  empty = fail "empty"
  x <|> y = x `catchAll` const y

instance (SomeException :< exceptions, Exception (Ex exceptions)) => MonadPlus (ObservableEx exceptions)

instance Semigroup a => Semigroup (ObservableEx exceptions a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (ObservableEx exceptions a) where
  mempty = pure mempty


-- * ObservableLoading

data ObservableLoading = ObservableLoading
  deriving stock (Show, Generic)

instance Exception ObservableLoading


-- * Convert Observable to Future

--observableMatches :: MonadSTMc NoRetry '[] m => (a -> Bool) -> Observable a -> m (Future a)
---- TODO remove monad `m` from signature after reworking the Future to allow callbacks
--observableMatches pred observable = do
--  promise <- newPromiseIO
