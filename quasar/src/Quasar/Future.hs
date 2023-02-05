{-# LANGUAGE UndecidableInstances #-}

module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureIO,
  awaitSTM,

  -- * Future
  IsFuture(..),
  IsFutureEx,
  Future,

  -- * Future helpers
  afix,
  afix_,
  afixExtra,

  -- ** Awaiting multiple futures
  anyFuture,
  any2Future,
  eitherFuture,

  -- * Promise
  Promise,

  -- ** Manage `Promise`s in STM
  newPromise,
  fulfillPromise,
  tryFulfillPromise,
  tryFulfillPromise_,

  -- ** Manage `Promise`s in IO
  newPromiseIO,
  fulfillPromiseIO,
  tryFulfillPromiseIO,
  tryFulfillPromiseIO_,

  -- * Exception variants
  FutureEx,
  toFutureEx,
  limitFutureEx,
  PromiseEx,
) where

import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Exception.Ex
import Control.Monad.Catch
import Control.Monad.RWS (RWST)
import Control.Monad.Reader
import Control.Monad.State (StateT)
import Control.Monad.Trans.Maybe
import Control.Monad.Writer (WriterT)
import Data.Coerce (coerce)
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Core


class Monad m => MonadAwait m where
  -- | Wait until a future is completed and then return it's value.
  await :: IsFuture r a => a -> m r

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait IO where
  await x =
    catch
      (atomically (liftSTMc (readFuture x)))
      \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

-- | `awaitSTM` exists as an explicit alternative to a `Future STM`-instance, to
-- prevent code which creates- and then awaits resources without knowing it's
-- running in STM (which would block indefinitely when run in STM).
awaitSTM :: MonadSTMc Retry '[] m => IsFuture r a => a -> m r
awaitSTM x = liftSTMc (readFuture x)

instance MonadAwait m => MonadAwait (ReaderT a m) where
  await = lift . await

instance (MonadAwait m, Monoid a) => MonadAwait (WriterT a m) where
  await = lift . await

instance MonadAwait m => MonadAwait (StateT a m) where
  await = lift . await

instance (MonadAwait m, Monoid w) => MonadAwait (RWST r w s m) where
  await = lift . await

instance MonadAwait m => MonadAwait (MaybeT m) where
  await = lift . await


type FutureCallback a = a -> STMc NoRetry '[] ()

class IsFuture r a | a -> r where
  -- | Read the value from a future or block until it is available.
  --
  -- For the lifted variant see `awaitSTM`.
  readFuture :: a -> STMc Retry '[] r
  readFuture x = readFuture (toFuture x)

  -- | Attach a callback to the future. The callback will be called when the
  -- future is fulfilled.
  --
  -- The resulting `TSimpleDisposer` can be used to deregister the callback.
  -- When the callback is called, the disposer must be disposed by the
  -- implementation of `attachFutureCallback` (i.e. the caller does not have to
  -- call dispose).
  attachFutureCallback :: a -> FutureCallback r -> STMc NoRetry '[] TSimpleDisposer
  attachFutureCallback x callback = attachFutureCallback (toFuture x) callback

  mapFuture :: (r -> r2) -> a -> Future r2
  mapFuture f = Future . MappedFuture f . toFuture

  cacheFuture :: MonadSTMc NoRetry '[] m => a -> m (Future r)
  cacheFuture f = liftSTMc $ Future <$> newCachedFuture (toFuture f)

  toFuture :: a -> Future r
  toFuture = Future

  {-# MINIMAL toFuture | readFuture, attachFutureCallback #-}

type IsFutureEx exceptions r = IsFuture (Either (Ex exceptions) r)


-- | Returns the result (in a `Just`) when the future is completed and returns
-- `Nothing` otherwise.
peekFuture :: MonadSTMc NoRetry '[] m => Future a -> m (Maybe a)
peekFuture future = orElseNothing (readFuture future)

-- | Returns the result (in a `Just`) when the future is completed and returns
-- `Nothing` otherwise.
peekFutureIO :: MonadIO m => Future r -> m (Maybe r)
peekFutureIO future = atomically $ peekFuture future


data Future r = forall a. IsFuture r a => Future a


instance Functor Future where
  fmap f x = toFuture (MappedFuture f x)

instance Applicative Future where
  pure x = toFuture (ConstFuture x)
  liftA2 f x y = toFuture (LiftA2Future f x y)

instance Monad Future where
  fx >>= fn = toFuture (BindFuture fx fn)


instance IsFuture a (Future a) where
  readFuture (Future x) = readFuture x
  attachFutureCallback (Future x) = attachFutureCallback x
  mapFuture f (Future x) = mapFuture f x
  toFuture = id

instance MonadAwait Future where
  await = toFuture

instance Semigroup a => Semigroup (Future a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Future a) where
  mempty = pure mempty


data ConstFuture a = ConstFuture a
instance IsFuture a (ConstFuture a) where
  readFuture (ConstFuture x) = pure x
  attachFutureCallback (ConstFuture x) callback =
    trivialTSimpleDisposer <$ callback x
  mapFuture f (ConstFuture x) = pure (f x)
  cacheFuture f = pure (toFuture f)

data MappedFuture a = forall b. MappedFuture (b -> a) (Future b)
instance IsFuture a (MappedFuture a) where
  readFuture (MappedFuture f future) = f <$> readFuture future
  attachFutureCallback (MappedFuture f future) callback =
    attachFutureCallback future (callback . f)
  mapFuture f1 (MappedFuture f2 future) =
    toFuture (MappedFuture (f1 . f2) future)


data LiftA2Future a =
  forall b c. LiftA2Future (b -> c -> a) (Future b) (Future c)

data LiftA2State a b = LiftA2Initial | LiftA2Left a | LiftA2Right b | LiftA2Done

instance IsFuture a (LiftA2Future a) where
  readFuture (LiftA2Future fn fx fy) = liftA2 fn (readFuture fx) (readFuture fy)

  attachFutureCallback (LiftA2Future fn fx fy) callback = do
    var <- newTVar LiftA2Initial
    d1 <- attachFutureCallback fx \x -> do
      readTVar var >>= \case
        LiftA2Initial -> writeTVar var (LiftA2Left x)
        LiftA2Right y -> dispatch var x y
        _ -> unreachableCodePath
    d2 <- attachFutureCallback fy \y -> do
      readTVar var >>= \case
        LiftA2Initial -> writeTVar var (LiftA2Right y)
        LiftA2Left x -> dispatch var x y
        _ -> unreachableCodePath
    pure (d1 <> d2)
    where
      dispatch var x y = do
        writeTVar var LiftA2Done
        callback (fn x y)

  mapFuture f (LiftA2Future fn fx fy) =
    toFuture (LiftA2Future (\x y -> f (fn x y)) fx fy)


data BindFuture a = forall b. BindFuture (Future b) (b -> Future a)

instance IsFuture a (BindFuture a) where
  readFuture (BindFuture fx fn) = readFuture . fn =<< readFuture fx

  attachFutureCallback (BindFuture fx fn) callback = do
    disposerVar <- newTVar Nothing
    d2 <- newUnmanagedTSimpleDisposer do
      mapM_ disposeTSimpleDisposer =<< swapTVar disposerVar Nothing
    d1 <- attachFutureCallback fx \x -> do
      disposer <- attachFutureCallback (fn x) \y -> do
        callback y
        disposeTSimpleDisposer d2
      writeTVar disposerVar (Just disposer)
    pure (d1 <> d2)


  mapFuture f (BindFuture fx fn) = toFuture (BindFuture fx (fmap f . fn))


data CachedFuture a = CachedFuture (TVar (CacheState a))
data CacheState a
  = CacheIdle (Future a)
  | CacheAttached (Future a) TSimpleDisposer (CallbackRegistry a)
  | Cached a

newCachedFuture :: Future a -> STMc NoRetry '[] (CachedFuture a)
newCachedFuture f = CachedFuture <$> newTVar (CacheIdle f)

instance IsFuture a (CachedFuture a) where
  readFuture x@(CachedFuture var) = do
    readTVar var >>= \case
      CacheIdle future -> readCacheUpstreamFuture x future
      CacheAttached future _ _ -> readCacheUpstreamFuture x future
      Cached value -> pure value

  attachFutureCallback x@(CachedFuture var) callback = do
    readTVar var >>= \case
      CacheIdle future -> setupCacheListener x future callback
      CacheAttached _ _ callbackRegistry ->
        registerCallback callbackRegistry callback
      Cached value -> mempty <$ callback value

  cacheFuture = pure . toFuture

setupCacheListener :: CachedFuture a -> Future a -> (a -> STMc NoRetry '[] ()) -> STMc NoRetry '[] TSimpleDisposer
setupCacheListener x@(CachedFuture var) future callback = do
  callbackRegistry <- newCallbackRegistryWithEmptyCallback (removeCacheListener x)
  callbackDisposer <- registerCallback callbackRegistry callback

  -- Write the registry before calling `attachFutureCallback` (even though
  -- we don't have the internal disposer yet), since the callback could
  -- be called by attachFutureCallback and that could change the state.
  writeTVar var (CacheAttached future mempty callbackRegistry)

  -- Attach to upstream future. Might result in the callback being called, which
  -- would change the state to Cached.
  internalDisposer <- attachFutureCallback future (fulfillCacheValue x)

  -- Now add internalDisposer to state or dispose it if the state is
  -- already `Cached`.
  readTVar var >>= \case
    CacheIdle _ ->
      -- This is an impossible state since we just attached a callback to
      -- the callbackRegistry, which cannot be detached until
      -- `callbackDisposer` is reachable from the outside of this
      -- function.
      unreachableCodePath
    CacheAttached future' disposer' callbackRegistry' ->
      -- NOTE: `disposer'` should be mempty since it is set to that before
      -- calling `attachFutureCallback`.
      writeTVar var (CacheAttached future' (disposer' <> internalDisposer) callbackRegistry')
    Cached _ -> disposeTSimpleDisposer internalDisposer

  pure callbackDisposer

removeCacheListener :: CachedFuture a -> STMc NoRetry '[] ()
removeCacheListener (CachedFuture var) = do
  readTVar var >>= \case
    CacheIdle _ -> unreachableCodePath
    CacheAttached future disposer _callbackRegistry -> do
      writeTVar var (CacheIdle future)
      disposeTSimpleDisposer disposer
    Cached _ -> pure ()

fulfillCacheValue :: CachedFuture a -> a -> STMc NoRetry '[] ()
fulfillCacheValue (CachedFuture var) value =
  swapTVar var (Cached value) >>= \case
    CacheIdle _ -> unreachableCodePath
    CacheAttached _ disposer registry -> do
      disposeTSimpleDisposer disposer
      callCallbacks registry value
    Cached _ -> pure ()

readCacheUpstreamFuture :: CachedFuture a -> Future a -> STMc Retry '[] a
readCacheUpstreamFuture cache future = do
  value <- readFuture future
  liftSTMc $ fulfillCacheValue cache value
  pure value


type FutureEx :: [Type] -> Type -> Type
newtype FutureEx exceptions a = FutureEx (Future (Either (Ex exceptions) a))

instance Functor (FutureEx exceptions) where
  fmap f x = FutureEx (mapFuture (fmap f) x)

instance Applicative (FutureEx exceptions) where
  pure x = FutureEx (pure (Right x))
  liftA2 f (FutureEx x) (FutureEx y) = FutureEx (liftA2 (liftA2 f) x y)

instance Monad (FutureEx exceptions) where
  (FutureEx x) >>= f = FutureEx $ x >>= \case
    (Left ex) -> pure (Left ex)
    Right y -> toFuture (f y)

instance IsFuture (Either (Ex exceptions) a) (FutureEx exceptions a) where
  toFuture (FutureEx f) = f

instance MonadAwait (FutureEx exceptions) where
  await f = FutureEx (Right <$> toFuture f)

instance (Exception e, e :< exceptions) => Throw e (FutureEx exceptions) where
  throwC ex = FutureEx $ pure (Left (toEx ex))

instance ThrowEx (FutureEx exceptions) where
  unsafeThrowEx = FutureEx . pure . Left . unsafeToEx @exceptions

instance SomeException :< exceptions => MonadThrow (FutureEx exceptions) where
  throwM = throwC . toException

instance (SomeException :< exceptions, Exception (Ex exceptions)) => MonadCatch (FutureEx exceptions) where
  catch (FutureEx x) f = FutureEx $ x >>= \case
    left@(Left ex) -> case fromException (toException ex) of
      Just matched -> toFuture (f matched)
      Nothing -> pure left
    Right y -> pure (Right y)

instance SomeException :< exceptions => MonadFail (FutureEx exceptions) where
  fail = throwM . userError

limitFutureEx :: sub :<< super => FutureEx sub a -> FutureEx super a
limitFutureEx (FutureEx f) = FutureEx $ coerce <$> f

toFutureEx ::
  forall exceptions r a.
  IsFuture (Either (Ex exceptions) r) a =>
  a -> FutureEx exceptions r
toFutureEx x = FutureEx (toFuture x)


-- ** Promise

-- | A value container that can be written once and implements `IsFuture`.
data Promise a = Promise (TMVar a) (CallbackRegistry a)

type PromiseEx exceptions a = Promise (Either (Ex exceptions) a)

instance IsFuture a (Promise a) where
  readFuture (Promise var _) = readTMVar var

  attachFutureCallback (Promise var registry) callback =
    tryReadTMVar var >>= \case
      Just value -> trivialTSimpleDisposer <$ callback value
      Nothing ->
        -- NOTE Using mfix to get the disposer is a safe because the registered
        -- method won't be called immediately.
        -- Modifying the callback to deregister itself is an inefficient hack
        -- that could be improved by writing a custom registry.
        mfix \disposer -> do
          registerCallback registry \value -> do
            callback value
            disposeTSimpleDisposer disposer

newPromise :: MonadSTMc NoRetry '[] m => m (Promise a)
newPromise = liftSTMc $ Promise <$> newEmptyTMVar <*> newCallbackRegistry

newPromiseIO :: MonadIO m => m (Promise a)
newPromiseIO = liftIO $ Promise <$> newEmptyTMVarIO <*> newCallbackRegistryIO

fulfillPromise :: MonadSTMc NoRetry '[PromiseAlreadyCompleted] m => Promise a -> a -> m ()
fulfillPromise var result = do
  success <- tryFulfillPromise var result
  unless success $ throwC PromiseAlreadyCompleted

fulfillPromiseIO :: MonadIO m => Promise a -> a -> m ()
fulfillPromiseIO var result = atomically $ fulfillPromise var result

tryFulfillPromise :: MonadSTMc NoRetry '[] m => Promise a -> a -> m Bool
tryFulfillPromise (Promise var registry) value = liftSTMc do
  success <- tryPutTMVar var value
  when success do
    -- Calling the callbacks will also deregister all callbacks due to the
    -- current implementation of `attachFutureCallback`.
    callCallbacks registry value
  pure success

tryFulfillPromise_ :: MonadSTMc NoRetry '[] m => Promise a -> a -> m ()
tryFulfillPromise_ var result = void $ tryFulfillPromise var result

tryFulfillPromiseIO :: MonadIO m => Promise a -> a -> m Bool
tryFulfillPromiseIO var result = atomically $ tryFulfillPromise var result

tryFulfillPromiseIO_ :: MonadIO m => Promise a -> a -> m ()
tryFulfillPromiseIO_ var result = void $ tryFulfillPromiseIO var result



-- * Utility functions

afix :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m a) -> m a
afix = afixExtra . fmap (fmap dup)

afix_ :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m a) -> m ()
afix_ = void . afix

afixExtra :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m (r, a)) -> m r
afixExtra action = do
  var <- newPromiseIO
  catchAll
    do
      (result, fixResult) <- action (toFutureEx var)
      fulfillPromiseIO var (Right fixResult)
      pure result
    \ex -> do
      fulfillPromiseIO var (Left (toEx ex))
      throwM ex


-- ** Awaiting multiple awaitables

data AnyFuture a = AnyFuture [Future a] (TVar (Maybe a))

instance IsFuture a (AnyFuture a) where
  readFuture (AnyFuture fs var) = do
    readTVar var >>= \case
      Just value -> pure value
      Nothing -> do
        result <- foldr orElseC retry (readFuture <$> fs)
        -- Read again in case during a "later" readFuture, an "earlier"
        -- readFuture became available to read (which should only happen
        -- as a rare edge case, but it's easy to handle it here).
        readTVar var >>= \case
          Just value -> pure value
          Nothing -> result <$ writeTVar var (Just result)

  attachFutureCallback (AnyFuture fs var) callback = do
    disposers <- mapM (\f -> attachFutureCallback f eitherCallback) fs
    pure (mconcat disposers)
    where
      eitherCallback value = do
        readTVar var >>= \case
          Just _ -> pure ()
          Nothing -> do
            writeTVar var (Just value)
            callback value


-- Completes as soon as any future in the list is completed and then returns the
-- left-most completed result.
anyFuture :: MonadSTMc NoRetry '[] m => [Future r] -> m (Future r)
anyFuture fs = toFuture <$> (AnyFuture fs <$> newTVar Nothing)

-- | Like `awaitAny` with two futures.
any2Future :: MonadSTMc NoRetry '[] m => Future r -> Future r -> m (Future r)
any2Future x y = anyFuture [toFuture x, toFuture y]

-- | Completes as soon as either future completes.
eitherFuture :: MonadSTMc NoRetry '[] m => Future ra -> Future rb -> m (Future (Either ra rb))
eitherFuture x y = any2Future (Left <$> x) (Right <$> y)


-- * Instance for TSimpleDisposerElement

instance IsFuture () TSimpleDisposerElement where
  readFuture (TSimpleDisposerElement _ stateVar _) = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> pure ()
      _ -> retry

  attachFutureCallback (TSimpleDisposerElement _ stateVar _) callback = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> trivialTSimpleDisposer <$ callback ()
      TSimpleDisposerDisposing registry -> registerDisposedCallback registry
      TSimpleDisposerNormal _ registry -> registerDisposedCallback registry
    where
      registerDisposedCallback registry = do
        -- NOTE Using mfix to get the disposer is a safe because the registered
        -- method won't be called immediately.
        -- Modifying the callback to deregister itself is an inefficient hack
        -- that could be improved by writing a custom registry.
        mfix \disposer -> do
          registerCallback registry \value -> do
            callback value
            disposeTSimpleDisposer disposer
