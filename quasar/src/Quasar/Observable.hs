{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Observable (
  -- * Observable core
  Observable,
  ToObservable(..),
  readObservable,
  attachObserver,
  mapObservable,
  deduplicateObservable,
  cacheObservable,
  IsObservable(..),
  observeSTM,
  ObserverCallback,
  observe,

  observeQ,
  observeQ_,

  -- ** Control flow utilities
  observeWith,
  observeBlocking,
  observeAsync,

  -- * ObservableEx
  ObservableEx,
  IsObservableEx,
  toObservableEx,
  limitObservableEx,

  -- * ObservableVar
  ObservableVar,
  newObservableVar,
  newObservableVarIO,
  writeObservableVar,
  modifyObservableVar,
  stateObservableVar,
  observableVarHasObservers,
) where

import Control.Applicative
import Control.Monad (MonadPlus)
import Control.Monad.Catch
import Data.Coerce (coerce)
import Data.String (IsString(..))
import Quasar.Async
import Quasar.Exceptions
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix

type ObserverCallback a = a -> STMc NoRetry '[] ()

class ToObservable r a | a -> r where
  toObservable :: a -> Observable r
  default toObservable :: IsObservable r a => a -> Observable r
  toObservable = Observable

class ToObservable r a => IsObservable r a | a -> r where
  {-# MINIMAL attachObserver#, readObservable# #-}

  readObservable# :: a -> STMc NoRetry '[] r

  -- | Register a callback to observe changes. The callback is called when the
  -- value changes, but depending on the observable implementation intermediate
  -- values may be skipped.
  --
  -- The implementation of `attachObserver#` MUST NOT call the callback during
  -- registration.
  --
  -- The implementation of `attachObserver#` MUST NOT directly or indirectly
  -- update an observable during the current STM transaction. Only working with
  -- `TVar`s and calling `registerCallback` is guaranteed to be safe.
  attachObserver# :: a -> ObserverCallback r -> STMc NoRetry '[] (TDisposer, r)

  mapObservable# :: (r -> r2) -> a -> Observable r2
  mapObservable# f o = Observable (MappedObservable f (toObservable o))

  cacheObservable# :: a -> STMc NoRetry '[] (Observable r)
  cacheObservable# o = Observable <$> newCachedObservable (toObservable o)

readObservable :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> m r
readObservable o = liftSTMc $ readObservable# (toObservable o)

attachObserver :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> ObserverCallback r -> m (TDisposer, r)
attachObserver o callback = liftSTMc $ attachObserver# (toObservable o) callback

mapObservable :: ToObservable r a => (r -> r2) -> a -> Observable r2
mapObservable f o = mapObservable# f (toObservable o)

cacheObservable :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> m (Observable r)
cacheObservable o = liftSTMc $ cacheObservable# (toObservable o)

-- | The implementation of `observeSTM` will call the callback during
-- registration.
observeSTM :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> ObserverCallback r -> m TDisposer
observeSTM observable callback = liftSTMc do
  (disposer, initial) <- attachObserver# (toObservable observable) callback
  callback initial
  pure disposer


instance ToObservable (Maybe r) (Future '[] r)

instance IsObservable (Maybe r) (Future '[] r) where
  readObservable# future = orElseNothing @'[] (fromEitherEx <$> readFuture future)

  attachObserver# future callback = do
    readOrAttachToFuture future (callback . Just . fromEitherEx) >>= \case
      Left disposer -> pure (disposer, Nothing)
      Right (RightAbsurdEx value) -> pure (mempty, Just value)

  cacheObservable# future = toObservable <$> cacheFuture# future

observe
  :: (ResourceCollector m, MonadSTMc NoRetry '[] m)
  => Observable a
  -> (a -> STMc NoRetry '[] ()) -- ^ callback
  -> m ()
observe observable callback = do
  disposer <- observeSTM observable callback
  collectResource disposer

observeQ
  :: (MonadQuasar m, MonadSTMc NoRetry '[SomeException] m)
  => Observable a
  -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
  -> m TDisposer
observeQ observable callbackFn = do
  sink <- askExceptionSink
  mfix \disposerFixed -> do
    let
      wrappedCallback state = callbackFn state `catchAllSTMc` \e -> do
        disposeTDisposer disposerFixed
        throwToExceptionSink sink e
    disposer <- observeSTM observable wrappedCallback
    collectResource disposer
    pure disposer

observeQ_
    :: (MonadQuasar m, MonadSTMc NoRetry '[SomeException] m)
    => Observable a
    -> (a -> STMc NoRetry '[SomeException] ()) -- ^ callback
    -> m ()
observeQ_ observable callback = void $ observeQ observable callback


-- | Existential quantification wrapper for the IsObservable type class.
data Observable r = forall a. IsObservable r a => Observable a

instance ToObservable a (Observable a) where
  toObservable = id

instance IsObservable a (Observable a) where
  readObservable# (Observable o) = readObservable# o
  attachObserver# (Observable o) = attachObserver# o
  mapObservable# f (Observable o) = mapObservable# f o
  cacheObservable# (Observable o) = cacheObservable# o

instance Functor Observable where
  fmap f = mapObservable# f

instance Applicative Observable where
  pure value = toObservable (ConstObservable value)
  liftA2 fn x y = toObservable $ LiftA2Observable fn x y

instance Monad Observable where
  x >>= f = toObservable $ BindObservable x f

instance Semigroup a => Semigroup (Observable a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Observable a) where
  mempty = pure mempty

instance IsString a => IsString (Observable a) where
  fromString = pure . fromString


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
    msg <- atomicallyC fetchNext
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
  -> (STMc Retry '[] r -> m a)
  -> m a
observeWith observable fn = do
  var <- liftIO newEmptyTMVarIO

  bracket (aquire var) dispose
    \_ -> fn (takeTMVar var)
  where
    aquire var = quasarAtomicallyC $ observeQ observable \msg -> do
      writeTMVar var msg


-- | Internal control flow exception for `observeWhile` and `observeWhile_`.
data ObserveWhileCompleted = ObserveWhileCompleted
  deriving stock (Eq, Show)


newtype ConstObservable a = ConstObservable a

instance ToObservable a (ConstObservable a)

instance IsObservable a (ConstObservable a) where
  attachObserver# (ConstObservable value) _ = pure (mempty, value)

  readObservable# (ConstObservable value) = pure value

  cacheObservable# = pure . toObservable


data MappedObservable a = forall b. MappedObservable (b -> a) (Observable b)

instance ToObservable a (MappedObservable a)

instance IsObservable a (MappedObservable a) where
  attachObserver# (MappedObservable fn observable) callback = fn <<$>> attachObserver# observable (callback . fn)
  readObservable# (MappedObservable fn observable) = fn <$> readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) = toObservable $ MappedObservable (f1 . f2) upstream


-- | Merge two observables using a given merge function. Whenever one of the inputs is updated, the resulting
-- observable updates according to the merge function.
--
-- There is no caching involed, every subscriber effectively subscribes to both input observables.
data LiftA2Observable r = forall a b. LiftA2Observable (a -> b -> r) (Observable a) (Observable b)

instance ToObservable a (LiftA2Observable a)

instance IsObservable a (LiftA2Observable a) where
  attachObserver# (LiftA2Observable fn fx fy) callback = do
    mfixExtra \(ixFix, iyFix) -> do
      var0 <- newTVar ixFix
      var1 <- newTVar iyFix
      let callCallback = do
            x <- readTVar var0
            y <- readTVar var1
            callback (fn x y)
      (dx, ix) <- attachObserver# fx (\update -> writeTVar var0 update >> callCallback)
      (dy, iy) <- attachObserver# fy (\update -> writeTVar var1 update >> callCallback)
      pure ((dx <> dy, fn ix iy), (ix, iy))

  readObservable# (LiftA2Observable fn fx fy) =
    liftA2 fn (readObservable# fx) (readObservable# fy)

  mapObservable# f1 (LiftA2Observable f2 fx fy) =
    toObservable $ LiftA2Observable (\x y -> f1 (f2 x y)) fx fy


data BindObservable a = forall b. BindObservable (Observable b) (b -> Observable a)

instance ToObservable a (BindObservable a)

instance IsObservable a (BindObservable a) where
  attachObserver# (BindObservable fx fn) callback = do
    mfixExtra \rightDisposerFix -> do
      rightDisposerVar <- newTVar rightDisposerFix
      (leftDisposer, ix) <- attachObserver# fx (leftCallback rightDisposerVar)
      (rightDisposer, iy) <- attachObserver# (fn ix) callback

      varDisposer <- newTDisposer do
        disposeTDisposer =<< swapTVar rightDisposerVar mempty
      pure ((leftDisposer <> varDisposer, iy), rightDisposer)

    where
      leftCallback rightDisposerVar lmsg = do
        disposeTDisposer =<< readTVar rightDisposerVar
        rightDisposer <- observeSTM (fn lmsg) callback
        writeTVar rightDisposerVar rightDisposer

  readObservable# (BindObservable fx fn) =
    readObservable# . fn =<< readObservable# fx

  mapObservable# f (BindObservable fx fn) =
    toObservable $ BindObservable fx (f <<$>> fn)


data CachedObservable a = CachedObservable (TVar (CacheState a))

data CacheState a
  = CacheIdle (Observable a)
  | CacheAttached (Observable a) TDisposer (CallbackRegistry a) a

instance ToObservable a (CachedObservable a)

instance IsObservable a (CachedObservable a) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle upstream -> readObservable# upstream
      CacheAttached _ _ _ value -> pure value

  attachObserver# (CachedObservable var) callback = do
    (value, registry) <- readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, value) <- attachObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry value)
        pure (value, registry)
      CacheAttached _ _ registry value ->
        pure (value, registry)
    disposer <- registerCallback registry callback
    pure (disposer, value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTDisposer upstreamDisposer
      updateCache :: a -> STMc NoRetry '[] ()
      updateCache value = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry _ -> do
            writeTVar var (CacheAttached upstream upstreamDisposer registry value)
            callCallbacks registry value

  cacheObservable# f = pure (Observable f)

newCachedObservable :: Observable a -> STMc NoRetry '[] (CachedObservable a)
newCachedObservable f = CachedObservable <$> newTVar (CacheIdle f)


newtype DeduplicatedObservable a = DeduplicatedObservable (Observable a)

instance Eq a => ToObservable a (DeduplicatedObservable a)

instance Eq a => IsObservable a (DeduplicatedObservable a) where
  readObservable# (DeduplicatedObservable upstream) = readObservable# upstream
  attachObserver# (DeduplicatedObservable upstream) callback =
    mfixExtra \initialFix -> do
      var <- newTVar initialFix
      (disposer, initialValue) <- attachObserver# upstream \value -> do
        old <- readTVar var
        when (old /= value) do
          writeTVar var value
          callback value
      pure ((disposer, initialValue), initialValue)

deduplicateObservable :: (Eq r, ToObservable r a) => a -> Observable r
deduplicateObservable x = Observable (DeduplicatedObservable (toObservable x))


data ObservableVar a = ObservableVar (TVar a) (CallbackRegistry a)

instance ToObservable a (ObservableVar a)

instance IsObservable a (ObservableVar a) where
  attachObserver# (ObservableVar var registry) callback = do
    disposer <- registerCallback registry callback
    value <- readTVar var
    pure (disposer, value)

  readObservable# = readObservableVar

  cacheObservable# = pure . toObservable

newObservableVar :: MonadSTMc NoRetry '[] m => a -> m (ObservableVar a)
newObservableVar x = liftSTMc $ ObservableVar <$> newTVar x <*> newCallbackRegistry

newObservableVarIO :: MonadIO m => a -> m (ObservableVar a)
newObservableVarIO x = liftIO $ ObservableVar <$> newTVarIO x <*> newCallbackRegistryIO

writeObservableVar :: MonadSTMc NoRetry '[] m => ObservableVar a -> a -> m ()
writeObservableVar (ObservableVar var registry) value = liftSTMc $ do
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
  writeObservableVar var newValue
  pure result

observableVarHasObservers :: MonadSTMc NoRetry '[] m => ObservableVar a -> m Bool
observableVarHasObservers (ObservableVar _ registry) =
  callbackRegistryHasCallbacks registry


-- * ObservableEx

newtype ObservableEx exceptions a = ObservableEx (Observable (Either (Ex exceptions) a))

instance ToObservable (Either (Ex exceptions) a) (ObservableEx exceptions a) where
  toObservable (ObservableEx o) = o

instance Functor (ObservableEx exceptions) where
  fmap f (ObservableEx x) = ObservableEx (mapObservable# (fmap f) x)

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

instance MonadThrowEx (ObservableEx exceptions) where
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

limitObservableEx :: sub :<< super => ObservableEx sub a -> ObservableEx super a
limitObservableEx (ObservableEx o) = ObservableEx $ coerce <$> o


type IsObservableEx exceptions a = IsObservable (Either (Ex exceptions) a)

toObservableEx :: Observable (Either (Ex exceptions) a) -> ObservableEx exceptions a
toObservableEx = ObservableEx


-- * Convert Observable to Future

--observableMatches :: MonadSTMc NoRetry '[] m => (a -> Bool) -> Observable a -> m (Future a)
---- TODO remove monad `m` from signature after reworking the Future to allow callbacks
--observableMatches pred observable = do
--  promise <- newPromiseIO
