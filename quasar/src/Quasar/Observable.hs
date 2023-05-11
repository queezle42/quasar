{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

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

  -- * Generalized observable
#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanWait(..),
#else
  CanWait,
  Wait,
  NoWait,
#endif
) where

import Control.Applicative
import Control.Monad.Catch
import Control.Monad.Except
import Data.Coerce (coerce)
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
  attachObserver# :: a -> ObserverCallback r -> STMc NoRetry '[] (TSimpleDisposer, r)

  mapObservable# :: (r -> r2) -> a -> Observable r2
  mapObservable# f o = Observable (MappedObservable f (toObservable o))

  cacheObservable# :: a -> STMc NoRetry '[] (Observable r)
  cacheObservable# o = Observable <$> newCachedObservable (toObservable o)

readObservable :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> m r
readObservable o = liftSTMc $ readObservable# (toObservable o)

attachObserver :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> ObserverCallback r -> m (TSimpleDisposer, r)
attachObserver o callback = liftSTMc $ attachObserver# (toObservable o) callback

mapObservable :: ToObservable r a => (r -> r2) -> a -> Observable r2
mapObservable f o = mapObservable# f (toObservable o)

cacheObservable :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> m (Observable r)
cacheObservable o = liftSTMc $ cacheObservable# (toObservable o)

-- | The implementation of `observeSTM` will call the callback during
-- registration.
observeSTM :: (ToObservable r a, MonadSTMc NoRetry '[] m) => a -> ObserverCallback r -> m TSimpleDisposer
observeSTM observable callback = liftSTMc do
  (disposer, initial) <- attachObserver# (toObservable observable) callback
  callback initial
  pure disposer


instance ToObservable (Maybe r) (Future r)

instance IsObservable (Maybe r) (Future r) where
  readObservable# future = orElseNothing @'[] (readFuture future)

  attachObserver# future callback = do
    readOrAttachToFuture future (callback . Just) >>= \case
      Left disposer -> pure (disposer, Nothing)
      Right value -> pure (mempty, Just value)

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
  -> m TSimpleDisposer
observeQ observable callbackFn = do
  sink <- askExceptionSink
  mfix \disposerFixed -> do
    let
      wrappedCallback state = callbackFn state `catchAllSTMc` \e -> do
        disposeTSimpleDisposer disposerFixed
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

      varDisposer <- newUnmanagedTSimpleDisposer do
        disposeTSimpleDisposer =<< swapTVar rightDisposerVar mempty
      pure ((leftDisposer <> varDisposer, iy), rightDisposer)

    where
      leftCallback rightDisposerVar lmsg = do
        disposeTSimpleDisposer =<< readTVar rightDisposerVar
        rightDisposer <- observeSTM (fn lmsg) callback
        writeTVar rightDisposerVar rightDisposer

  readObservable# (BindObservable fx fn) =
    readObservable# . fn =<< readObservable# fx

  mapObservable# f (BindObservable fx fn) =
    toObservable $ BindObservable fx (f <<$>> fn)


data CachedObservable a = CachedObservable (TVar (CacheState a))

data CacheState a
  = CacheIdle (Observable a)
  | CacheAttached (Observable a) TSimpleDisposer (CallbackRegistry a) a

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
            disposeTSimpleDisposer upstreamDisposer
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


-- * Generalized observables

type ToGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  toGeneralizedObservable :: a -> GeneralizedObservable canWait exceptions delta value
  default toGeneralizedObservable :: IsGeneralizedObservable canWait exceptions delta value a => a -> GeneralizedObservable canWait exceptions delta value
  toGeneralizedObservable = GeneralizedObservable

type IsGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class ToGeneralizedObservable canWait exceptions delta value a => IsGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  {-# MINIMAL readObservable'#, (attachObserver'# | attachStateObserver#) #-}
  readObservable'# :: a -> STMc NoRetry '[] (Final, ObservableState canWait exceptions value)

  attachObserver'# :: IsObservableDelta delta value => a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachObserver'# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateWaiting _ -> ObservableChangeWaiting
      ObservableChangeWithStateUpdate delta _ -> ObservableChangeUpdate delta

  attachStateObserver# :: IsObservableDelta delta value => a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachStateObserver# x callback =
    mfixTVar \var -> do
      (disposer, final, initial) <- attachObserver'# x \final change -> do
        merged <- stateTVar var \oldState ->
          let merged = applyObservableChangeMerged change oldState
          in (merged, changeWithStateToState merged)
        callback final merged
      pure ((disposer, final, initial), initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable'# :: IsObservableDelta delta value => (value -> n) -> a -> Observable' canWait exceptions n
  mapObservable'# f (evaluateObservable# -> Some x) = Observable' (GeneralizedObservable (MappedObservable' f x))

  mapObservableDelta# :: (IsObservableDelta delta value, IsObservableDelta newDelta newValue) => (delta -> newDelta) -> (value -> newValue) -> a -> GeneralizedObservable canWait exceptions newDelta newValue
  mapObservableDelta# fd fn x = GeneralizedObservable (DeltaMappedObservable fd fn x)

readObservable'
  :: (ToGeneralizedObservable NoWait exceptions delta value a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m value
readObservable' x = case toGeneralizedObservable x of
  (ConstObservable' state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable'# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => ObservableState NoWait exceptions a -> m a
    extractState (ObservableStateValue z) = either throwEx pure z

attachObserver' :: (ToGeneralizedObservable canWait exceptions delta value a, IsObservableDelta delta value, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachObserver' x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver'# f callback
    ConstObservable' c -> pure (mempty, True, c)

attachStateObserver' :: (ToGeneralizedObservable canWait exceptions delta value a, IsObservableDelta delta value, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachStateObserver' x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachStateObserver# f callback
    ConstObservable' c -> pure (mempty, True, c)

isCachedObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Bool
isCachedObservable x = case toGeneralizedObservable x of
  GeneralizedObservable notConst -> isCachedObservable# notConst
  ConstObservable' _value -> True

mapObservable' :: (ToGeneralizedObservable canWait exceptions delta value a, IsObservableDelta delta value) => (value -> f) -> a -> Observable' canWait exceptions f
mapObservable' fn x = case toGeneralizedObservable x of
  (GeneralizedObservable x) -> mapObservable'# fn x
  (ConstObservable' state) -> Observable' (ConstObservable' (fn <$> state))

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanWait = Wait | NoWait
#else
data CanWait = Wait | NoWait
type Wait = 'Wait
type NoWait = 'NoWait
#endif

type ObservableChange :: CanWait -> [Type] -> Type -> Type
data ObservableChange canWait exceptions delta where
  ObservableChangeWaiting :: ObservableChange Wait exceptions delta
  ObservableChangeUpdate :: Maybe (Either (Ex exceptions) delta) -> ObservableChange canWait exceptions delta

type ObservableState :: CanWait -> [Type] -> Type -> Type
data ObservableState canWait exceptions value where
  ObservableStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableState Wait exceptions value
  ObservableStateValue :: Either (Ex exceptions) value -> ObservableState canWait exceptions value

type ObservableChangeWithState :: CanWait -> [Type] -> Type -> Type -> Type
data ObservableChangeWithState canWait exceptions delta value where
  ObservableChangeWithStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableChangeWithState Wait exceptions delta value
  ObservableChangeWithStateUpdate :: Maybe (Either (Ex exceptions) delta) -> Either (Ex exceptions) value -> ObservableChangeWithState canWait exceptions delta value

instance Functor (ObservableChange canWait exceptions) where
  fmap _ ObservableChangeWaiting = ObservableChangeWaiting
  fmap fn (ObservableChangeUpdate x) = ObservableChangeUpdate (fn <<$>> x)

instance Functor (ObservableState canWait exceptions) where
  fmap fn (ObservableStateWaiting x) = ObservableStateWaiting (fn <<$>> x)
  fmap fn (ObservableStateValue x) = ObservableStateValue (fn <$> x)

applyObservableChange :: IsObservableDelta delta value => ObservableChange canWait exceptions delta -> ObservableState canWait exceptions value -> ObservableState canWait exceptions value
-- Set to loading
applyObservableChange ObservableChangeWaiting (ObservableStateValue x) = ObservableStateWaiting (Just x)
applyObservableChange ObservableChangeWaiting x@(ObservableStateWaiting _) = x
-- Reactivate old value
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateWaiting (Just x)) = ObservableStateValue x
-- NOTE: An update is ignored for uncached waiting state.
applyObservableChange (ObservableChangeUpdate Nothing) x@(ObservableStateWaiting Nothing) = x
applyObservableChange (ObservableChangeUpdate Nothing) x@(ObservableStateValue _) = x
-- Update with exception delta
applyObservableChange (ObservableChangeUpdate (Just (Left x))) _ = ObservableStateValue (Left x)
-- Update with value delta
applyObservableChange (ObservableChangeUpdate (Just (Right x))) y =
  ObservableStateValue (Right (applyDelta x (getStateValue y)))
  where
    getStateValue :: ObservableState canWait exceptions a -> Maybe a
    getStateValue (ObservableStateWaiting (Just (Right value))) = Just value
    getStateValue (ObservableStateValue (Right value)) = Just value
    getStateValue _ = Nothing

applyObservableChangeMerged :: IsObservableDelta delta value => ObservableChange canWait exceptions delta -> ObservableState canWait exceptions value -> ObservableChangeWithState canWait exceptions delta value
-- Set to loading
applyObservableChangeMerged ObservableChangeWaiting (ObservableStateValue x) = ObservableChangeWithStateWaiting (Just x)
applyObservableChangeMerged ObservableChangeWaiting (ObservableStateWaiting x) = ObservableChangeWithStateWaiting x
-- Reactivate old value
applyObservableChangeMerged (ObservableChangeUpdate Nothing) (ObservableStateWaiting (Just x)) = ObservableChangeWithStateUpdate Nothing x
-- NOTE: An update is ignored for uncached waiting state.
applyObservableChangeMerged (ObservableChangeUpdate Nothing) (ObservableStateWaiting Nothing) = ObservableChangeWithStateWaiting Nothing
applyObservableChangeMerged (ObservableChangeUpdate Nothing) (ObservableStateValue x) = ObservableChangeWithStateUpdate Nothing x
-- Update with exception delta
applyObservableChangeMerged (ObservableChangeUpdate delta@(Just (Left x))) _ = ObservableChangeWithStateUpdate delta (Left x)
-- Update with value delta
applyObservableChangeMerged (ObservableChangeUpdate delta@(Just (Right x))) y =
  ObservableChangeWithStateUpdate delta (Right (applyDelta x (getStateValue y)))
  where
    getStateValue :: ObservableState canWait exceptions a -> Maybe a
    getStateValue (ObservableStateWaiting (Just (Right value))) = Just value
    getStateValue (ObservableStateValue (Right value)) = Just value
    getStateValue _ = Nothing

changeWithStateToChange :: ObservableChangeWithState canWait exceptions delta value -> ObservableChange canWait exceptions delta
changeWithStateToChange (ObservableChangeWithStateWaiting _cached) = ObservableChangeWaiting
changeWithStateToChange (ObservableChangeWithStateUpdate delta _value) = ObservableChangeUpdate delta

changeWithStateToState :: ObservableChangeWithState canWait exceptions delta value -> ObservableState canWait exceptions value
changeWithStateToState (ObservableChangeWithStateWaiting cached) = ObservableStateWaiting cached
changeWithStateToState (ObservableChangeWithStateUpdate _delta value) = ObservableStateValue value


type GeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data GeneralizedObservable canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => GeneralizedObservable a
  | ConstObservable' (ObservableState canWait exceptions value)

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (GeneralizedObservable canWait exceptions delta value) where
  toGeneralizedObservable = id

class IsObservableDelta delta value where
  applyDelta :: delta -> Maybe value -> value
  mergeDelta :: delta -> delta -> delta

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions delta value a => a -> Some (IsGeneralizedObservable canWait exceptions value value)
  evaluateObservable# x = Some (EvaluatedObservable x)

  toObservable' :: ToGeneralizedObservable canWait exceptions delta value a => a -> Observable' canWait exceptions value
  toObservable' x = Observable'
    case toGeneralizedObservable x of
      (GeneralizedObservable f) -> GeneralizedObservable (EvaluatedObservable f)
      (ConstObservable' c) -> ConstObservable' c

instance IsObservableDelta a a where
  applyDelta new _ = new
  mergeDelta _ new = new
  evaluateObservable# x = Some x
  toObservable' x = Observable' (toGeneralizedObservable x)


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data EvaluatedObservable canWait exceptions delta value = forall a. IsGeneralizedObservable canWait exceptions delta value a => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value)

instance IsGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value) where
  readObservable'# (EvaluatedObservable x) = readObservable'# x
  attachStateObserver# (EvaluatedObservable x) callback =
    attachStateObserver# x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateWaiting cache -> ObservableChangeWithStateWaiting cache
        -- Replace delta with evaluated value
        ObservableChangeWithStateUpdate _delta content -> ObservableChangeWithStateUpdate (Just content) content


data DeltaMappedObservable canWait exceptions delta value = forall oldDelta oldValue a. IsGeneralizedObservable canWait exceptions oldDelta oldValue a => DeltaMappedObservable (oldDelta -> delta) (oldValue -> value) a

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value)

instance IsObservableDelta delta value => IsGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value) where
  attachObserver'# (DeltaMappedObservable deltaFn valueFn observable) callback =
    fmap3 valueFn $ attachObserver'# observable \final change ->
      callback final (deltaFn <$> change)
  readObservable'# (DeltaMappedObservable _deltaFn valueFn observable) =
    fmap3 valueFn $ readObservable'# observable
  mapObservableDelta# fd1 fn1 (DeltaMappedObservable fd2 fn2 x) = GeneralizedObservable (DeltaMappedObservable (fd1 . fd2) (fn1 . fn2) x)


-- ** Cache

newtype CachedObservable' canWait exceptions delta value = CachedObservable' (TVar (CacheState' canWait exceptions delta value))

data CacheState' canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => CacheIdle' a
  | forall a. IsGeneralizedObservable canWait exceptions delta value a =>
    CacheAttached'
      a
      TSimpleDisposer
      (CallbackRegistry (Final, ObservableChangeWithState canWait exceptions delta value))
      (ObservableState canWait exceptions value)
  | CacheFinalized (ObservableState canWait exceptions value)

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (CachedObservable' canWait exceptions delta value)

instance IsObservableDelta delta value => IsGeneralizedObservable canWait exceptions delta value (CachedObservable' canWait exceptions delta value) where
  readObservable'# (CachedObservable' var) = do
    readTVar var >>= \case
      CacheIdle' x -> readObservable'# x
      CacheAttached' _x _disposer _registry state -> pure (False, state)
      CacheFinalized state -> pure (True, state)
  attachStateObserver# (CachedObservable' var) callback = do
    readTVar var >>= \case
      CacheIdle' upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, final, value) <- attachStateObserver# upstream updateCache
        writeTVar var (CacheAttached' upstream upstreamDisposer registry value)
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, final, value)
      CacheAttached' _ _ registry value -> do
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, False, value)
      CacheFinalized value -> pure (mempty, True, value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle' _ -> unreachableCodePath
          CacheAttached' upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle' upstream)
            disposeTSimpleDisposer upstreamDisposer
          CacheFinalized _ -> pure ()
      updateCache :: Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()
      updateCache final change = do
        readTVar var >>= \case
          CacheIdle' _ -> unreachableCodePath
          CacheAttached' upstream upstreamDisposer registry _ ->
            if final
              then do
                writeTVar var (CacheFinalized (changeWithStateToState change))
                callCallbacks registry (final, change)
                clearCallbackRegistry registry
              else do
                writeTVar var (CacheAttached' upstream upstreamDisposer registry (changeWithStateToState change))
                callCallbacks registry (final, change)
          CacheFinalized _ -> pure () -- Upstream implementation error

  isCachedObservable# _ = True

cacheObservable' :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> m (GeneralizedObservable canWait exceptions delta value)
cacheObservable' x =
  case toGeneralizedObservable x of
    c@(ConstObservable' _) -> pure c
    y@(GeneralizedObservable f) ->
      if isCachedObservable# f
        then pure y
        else GeneralizedObservable . CachedObservable' <$> newTVar (CacheIdle' f)


-- *** Embedded cache in the Observable monad

data CacheObservableOperation canWait exceptions w e d v = forall a. ToGeneralizedObservable w e d v a => CacheObservableOperation a

instance ToGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v)

instance IsGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v) where
  readObservable'# (CacheObservableOperation x) = do
    cache <- cacheObservable' x
    pure (True, ObservableStateValue (Right cache))
  attachObserver'# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable' x
    pure (mempty, True, ObservableStateValue (Right cache))

-- | Cache an observable in the `Observable` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
cacheObservableOperation :: forall canWait exceptions w e d v a. ToGeneralizedObservable w e d v a => a -> Observable' canWait exceptions (GeneralizedObservable w e d v)
cacheObservableOperation x =
  case toGeneralizedObservable x of
    c@(ConstObservable' _) -> pure c
    (GeneralizedObservable f) -> Observable' (GeneralizedObservable (CacheObservableOperation @canWait @exceptions f))


-- ** Observable

type Observable' :: CanWait -> [Type] -> Type -> Type
newtype Observable' canWait exceptions a = Observable' (GeneralizedObservable canWait exceptions a a)
type ToObservable' canWait exceptions a = ToGeneralizedObservable canWait exceptions a a
type IsObservable' canWait exceptions a = IsGeneralizedObservable canWait exceptions a a

instance ToGeneralizedObservable canWait exceptions value value (Observable' canWait exceptions value) where
  toGeneralizedObservable (Observable' x) = x

instance Functor (Observable' canWait exceptions) where
  fmap = undefined

instance Applicative (Observable' canWait exceptions) where
  pure = undefined
  liftA2 = undefined

instance Monad (Observable' canWait exceptions) where
  (>>=) = undefined


data MappedObservable' canWait exceptions value = forall prev a. IsGeneralizedObservable canWait exceptions prev prev a => MappedObservable' (prev -> value) a

instance ToGeneralizedObservable canWait exceptions value value (MappedObservable' canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions value value (MappedObservable' canWait exceptions value) where
  attachObserver'# (MappedObservable' fn observable) callback =
    fmap3 fn $ attachObserver'# observable \final change ->
      callback final (fn <$> change)
  readObservable'# (MappedObservable' fn observable) =
    fmap3 fn $ readObservable'# observable
  mapObservable'# f1 (MappedObservable' f2 upstream) =
    toObservable' $ MappedObservable' (f1 . f2) upstream


-- * Some

data Some c = forall a. c a => Some a
