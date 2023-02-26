{-# LANGUAGE UndecidableInstances #-}

module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureIO,
  awaitSTM,

  -- * Future
  ToFuture(..),
  readFuture,
  readOrAttachToFuture,
  callOnceCompleted,
  mapFuture,
  cacheFuture,
  IsFuture(..),
  ToFutureEx,
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
import Control.Monad.Trans (MonadTrans, lift)
import Data.Coerce (coerce)
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Resources.Core
import Quasar.Utils.Fix


class Monad m => MonadAwait m where
  -- | Wait until a future is completed and then return it's value.
  await :: ToFuture r a => a -> m r

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait IO where
  await x =
    catch
      (atomically (readFuture x))
      \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

awaitSTM :: MonadSTMc Retry '[] m => ToFuture r a => a -> m r
awaitSTM x = readFuture x
{-# DEPRECATED awaitSTM "Use readFuture instead" #-}

instance (MonadTrans t, MonadAwait m, Monad (t m)) => MonadAwait (t m) where
  await = lift . await


type FutureCallback a = a -> STMc NoRetry '[] ()

class ToFuture r a | a -> r where
  toFuture :: a -> Future r
  default toFuture :: IsFuture r a => a -> Future r
  toFuture = Future

class ToFuture r a => IsFuture r a | a -> r where
  {-# MINIMAL readFuture#, readOrAttachToFuture# #-}

  -- | Read the value from a future or block until it is available.
  --
  -- For the lifted variant see `readFuture`.
  --
  -- The implementation of `readFuture#` MUST NOT directly or indirectly
  -- complete a future. Only working with `TVar`s is guaranteed to be safe.
  readFuture# :: a -> STMc Retry '[] r

  -- | If the future is already completed, the value is returned in a `Right`.
  -- Otherwise the callback is attached to the future and will be called once
  -- the future is completed.
  --
  -- The resulting `TSimpleDisposer` can be used to deregister the callback.
  -- When the callback is called, the disposer must be disposed by the
  -- implementation of `readOrAttachToFuture#` (i.e. the caller does not have to
  -- call `dispose`).
  --
  -- The implementation of `readOrAttachToFuture#` MUST NOT call the callback
  -- during registration.
  --
  -- The implementation of `readOrAttachToFuture#` MUST NOT directly or
  -- indirectly complete a future during the current STM transaction. Only
  -- working with `TVar`s and calling `registerCallback` are guaranteed to be
  -- safe.
  readOrAttachToFuture# :: a -> FutureCallback r -> STMc NoRetry '[] (Either TSimpleDisposer r)

  mapFuture# :: (r -> r2) -> a -> Future r2
  mapFuture# f = Future . MappedFuture f . toFuture

  cacheFuture# :: a -> STMc NoRetry '[] (Future r)
  cacheFuture# f = Future <$> newCachedFuture (toFuture f)


readFuture :: (ToFuture r a, MonadSTMc Retry '[] m) => a -> m r
readFuture x = liftSTMc $ readFuture# (toFuture x)

readOrAttachToFuture :: (ToFuture r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback r -> m (Either TSimpleDisposer r)
readOrAttachToFuture x callback = liftSTMc $ readOrAttachToFuture# (toFuture x) callback

-- | Will call the callback immediately if the future is already completed.
callOnceCompleted :: (ToFuture r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback r -> m TSimpleDisposer
callOnceCompleted future callback = liftSTMc do
  readOrAttachToFuture future callback >>= \case
    Left disposer -> pure disposer
    Right value -> mempty <$ callback value

callOnceCompleted_ :: (ToFuture r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback r -> m ()
callOnceCompleted_ future callback = void $ callOnceCompleted future callback

mapFuture :: ToFuture r a => (r -> r2) -> a -> Future r2
mapFuture f future = mapFuture# f (toFuture future)

cacheFuture :: (ToFuture r a, MonadSTMc NoRetry '[] m) => a -> m (Future r)
cacheFuture f = liftSTMc $ cacheFuture# (toFuture f)

type ToFutureEx exceptions r = ToFuture (Either (Ex exceptions) r)


-- | Returns the result (in a `Just`) when the future is completed and returns
-- `Nothing` otherwise.
peekFuture :: MonadSTMc NoRetry '[] m => Future a -> m (Maybe a)
peekFuture future = orElseNothing (readFuture# future)

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


instance ToFuture a (Future a) where
  toFuture = id

instance IsFuture a (Future a) where
  readFuture# (Future x) = readFuture# x
  readOrAttachToFuture# (Future x) = readOrAttachToFuture# x
  mapFuture# f (Future x) = mapFuture# f x
  cacheFuture# (Future x) = cacheFuture# x

instance MonadAwait Future where
  await = toFuture

instance Semigroup a => Semigroup (Future a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Future a) where
  mempty = pure mempty


data ConstFuture a = ConstFuture a

instance ToFuture a (ConstFuture a)

instance IsFuture a (ConstFuture a) where
  readFuture# (ConstFuture x) = pure x
  readOrAttachToFuture# (ConstFuture x) _ = pure (Right x)
  mapFuture# f (ConstFuture x) = pure (f x)
  cacheFuture# f = pure (toFuture f)

data MappedFuture a = forall b. MappedFuture (b -> a) (Future b)

instance ToFuture a (MappedFuture a)

instance IsFuture a (MappedFuture a) where
  readFuture# (MappedFuture f future) = f <$> readFuture# future
  readOrAttachToFuture# (MappedFuture f future) callback =
    f <<$>> readOrAttachToFuture# future (callback . f)
  mapFuture# f1 (MappedFuture f2 future) =
    toFuture (MappedFuture (f1 . f2) future)


data LiftA2Future a =
  forall b c. LiftA2Future (b -> c -> a) (Future b) (Future c)

data LiftA2State a b = LiftA2Initial | LiftA2Left a | LiftA2Right b | LiftA2Done

instance ToFuture a (LiftA2Future a)

instance IsFuture a (LiftA2Future a) where
  readFuture# (LiftA2Future fn fx fy) = liftA2 fn (readFuture# fx) (readFuture# fy)

  readOrAttachToFuture# (LiftA2Future fn fx fy) callback =
    mfixExtra \s -> do
      var <- newTVar s
      r1 <- readOrAttachToFuture# fx \x -> do
        readTVar var >>= \case
          LiftA2Initial -> writeTVar var (LiftA2Left x)
          LiftA2Right y -> dispatch var x y
          _ -> unreachableCodePath
      r2 <- readOrAttachToFuture# fy \y -> do
        readTVar var >>= \case
          LiftA2Initial -> writeTVar var (LiftA2Right y)
          LiftA2Left x -> dispatch var x y
          _ -> unreachableCodePath
      pure case (r1, r2) of
        (Right v1, Right v2) -> (Right (fn v1 v2), LiftA2Done)
        (Right v1, Left d2) -> (Left d2, LiftA2Left v1)
        (Left d1, Right v2) -> (Left d1, LiftA2Right v2)
        (Left d1, Left d2) -> (Left (d1 <> d2), LiftA2Initial)
    where
      dispatch var x y = do
        writeTVar var LiftA2Done
        callback (fn x y)

  mapFuture# f (LiftA2Future fn fx fy) =
    toFuture (LiftA2Future (\x y -> f (fn x y)) fx fy)


data BindFuture a = forall b. BindFuture (Future b) (b -> Future a)

instance ToFuture a (BindFuture a)

instance IsFuture a (BindFuture a) where
  readFuture# (BindFuture fx fn) = readFuture# . fn =<< readFuture# fx

  readOrAttachToFuture# (BindFuture fx fn) callback = do
    disposerVar <- newTVar Nothing
    dyWrapper <- newUnmanagedTSimpleDisposer do
      mapM_ disposeTSimpleDisposer =<< swapTVar disposerVar Nothing
    rx <- readOrAttachToFuture# fx \x -> do
      ry <- readOrAttachToFuture# (fn x) \y -> do
        callback y
        disposeTSimpleDisposer dyWrapper
      case ry of
        Left dy -> do
          writeTVar disposerVar (Just dy)
          callOnceCompleted_ dy \() ->
            -- This is not a loop since disposing a TSimpleDisposer is
            -- reentrant-safe
            disposeTSimpleDisposer dyWrapper
        Right y -> do
          callback y
          disposeTSimpleDisposer dyWrapper
    result <- case rx of
      Left dx -> pure (Left (dx <> dyWrapper))
      -- LHS already completed, so trivially defer to RHS
      Right x -> readOrAttachToFuture# (fn x) callback
    pure result


  mapFuture# f (BindFuture fx fn) = toFuture (BindFuture fx (fmap f . fn))


data CachedFuture a = CachedFuture (TVar (CacheState a))
data CacheState a
  = CacheIdle (Future a)
  | CacheAttached (Future a) TSimpleDisposer (CallbackRegistry a)
  | Cached a

newCachedFuture :: Future a -> STMc NoRetry '[] (CachedFuture a)
newCachedFuture f = CachedFuture <$> newTVar (CacheIdle f)

instance ToFuture a (CachedFuture a)

instance IsFuture a (CachedFuture a) where
  readFuture# x@(CachedFuture var) = do
    readTVar var >>= \case
      CacheIdle future -> readCacheUpstreamFuture x future
      CacheAttached future _ _ -> readCacheUpstreamFuture x future
      Cached value -> pure value

  readOrAttachToFuture# x@(CachedFuture var) callback = do
    readTVar var >>= \case
      CacheIdle future -> do
        readOrAttachToFuture# future (fulfillCacheValue x) >>= \case
          Left disposer -> do
            callbackRegistry <- newCallbackRegistryWithEmptyCallback (removeCacheListener x)
            callbackDisposer <- registerCallback callbackRegistry callback
            writeTVar var (CacheAttached future disposer callbackRegistry)
            pure (Left callbackDisposer)
          Right value -> do
            writeTVar var (Cached value)
            pure (Right value)
      CacheAttached _ _ callbackRegistry ->
        Left <$> registerCallback callbackRegistry callback
      Cached value -> pure (Right value)

  cacheFuture# = pure . toFuture

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
    CacheIdle _ -> pure ()
    CacheAttached _ disposer registry -> do
      disposeTSimpleDisposer disposer
      callCallbacks registry value
    Cached _ -> pure ()

readCacheUpstreamFuture :: CachedFuture a -> Future a -> STMc Retry '[] a
readCacheUpstreamFuture cache future = do
  value <- readFuture# future
  liftSTMc $ fulfillCacheValue cache value
  pure value


type FutureEx :: [Type] -> Type -> Type
newtype FutureEx exceptions a = FutureEx (Future (Either (Ex exceptions) a))

instance Functor (FutureEx exceptions) where
  fmap f (FutureEx x) = FutureEx (mapFuture# (fmap f) x)

instance Applicative (FutureEx exceptions) where
  pure x = FutureEx (pure (Right x))
  liftA2 f (FutureEx x) (FutureEx y) = FutureEx (liftA2 (liftA2 f) x y)

instance Monad (FutureEx exceptions) where
  (FutureEx x) >>= f = FutureEx $ x >>= \case
    (Left ex) -> pure (Left ex)
    Right y -> toFuture (f y)

instance ToFuture (Either (Ex exceptions) a) (FutureEx exceptions a) where
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
  ToFuture (Either (Ex exceptions) r) a =>
  a -> FutureEx exceptions r
toFutureEx x = FutureEx (toFuture x)


-- ** Promise

-- | A value container that can be written once and implements `IsFuture`.
newtype Promise a = Promise (TVar (Either (CallbackRegistry a) a))

type PromiseEx exceptions a = Promise (Either (Ex exceptions) a)

instance ToFuture a (Promise a)

instance IsFuture a (Promise a) where
  readFuture# (Promise var) =
    readTVar var >>= \case
      Left _ -> retry
      Right value -> pure value

  readOrAttachToFuture# (Promise var) callback =
    readTVar var >>= \case
      Right value -> pure (Right value)
      Left registry ->
        -- NOTE Using mfix to get the disposer is a safe because the registered
        -- method won't be called immediately.
        -- Modifying the callback to deregister itself is an inefficient hack
        -- that could be improved by writing a custom registry.
        Left <$> mfix \disposer -> do
          registerCallback registry \value -> do
            callback value
            disposeTSimpleDisposer disposer

newPromise :: MonadSTMc NoRetry '[] m => m (Promise a)
newPromise = liftSTMc $ Promise <$> (newTVar . Left =<< newCallbackRegistry)

newPromiseIO :: MonadIO m => m (Promise a)
newPromiseIO = liftIO $ Promise <$> (newTVarIO . Left =<< newCallbackRegistryIO)

fulfillPromise :: MonadSTMc NoRetry '[PromiseAlreadyCompleted] m => Promise a -> a -> m ()
fulfillPromise var result = do
  success <- tryFulfillPromise var result
  unless success $ throwC PromiseAlreadyCompleted

fulfillPromiseIO :: MonadIO m => Promise a -> a -> m ()
fulfillPromiseIO var result = atomically $ fulfillPromise var result

tryFulfillPromise :: MonadSTMc NoRetry '[] m => Promise a -> a -> m Bool
tryFulfillPromise (Promise var) value = liftSTMc do
  readTVar var >>= \case
    Left registry -> do
      writeTVar var (Right value)
      -- Calling the callbacks will also deregister all callbacks due to the
      -- current implementation of `attachFutureCallback#`.
      callCallbacks registry value
      pure True
    Right _ -> pure False

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

instance ToFuture a (AnyFuture a)

instance IsFuture a (AnyFuture a) where
  readFuture# (AnyFuture fs var) = do
    readTVar var >>= \case
      Just value -> pure value
      Nothing -> do
        value <- foldr orElseC retry (readFuture# <$> fs)
        writeTVar var (Just value)
        pure value

  readOrAttachToFuture# (AnyFuture futures var) callback = do
    readTVar var >>= \case
      Just value -> pure (Right value)
      Nothing -> go futures []
    where
      go :: [Future a] -> [TSimpleDisposer] -> STMc NoRetry '[] (Either TSimpleDisposer a)
      go [] acc = pure (Left (mconcat acc))
      go (f : fs) acc = do
        readOrAttachToFuture# f internalCallback >>= \case
          Left disposer -> go fs (disposer : acc)
          Right value -> do
            mapM_ disposeTSimpleDisposer acc
            writeTVar var (Just value)
            pure (Right value)

      internalCallback value = do
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

instance ToFuture () TSimpleDisposerElement

instance IsFuture () TSimpleDisposerElement where
  readFuture# (TSimpleDisposerElement _ stateVar _) = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> pure ()
      _ -> retry

  readOrAttachToFuture# (TSimpleDisposerElement _ stateVar _) callback = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> pure (Right ())
      TSimpleDisposerDisposing registry -> Left <$> registerDisposedCallback registry
      TSimpleDisposerNormal _ registry -> Left <$> registerDisposedCallback registry
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

instance ToFuture () TSimpleDisposer where
  toFuture (TSimpleDisposer elements) = mconcat $ toFuture <$> elements
