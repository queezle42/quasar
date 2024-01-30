{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureIO,

  -- * Future
  ToFuture(..),
  readFuture,
  readOrAttachToFuture,
  readOrAttachToFuture_,
  callOnceCompleted,
  callOnceCompleted_,
  mapFuture,
  cacheFuture,
  IsFuture(..),
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
  PromiseEx,
  execToPromiseEx,
) where

import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Exception.Ex
import Control.Monad.Catch
import Control.Monad.Trans (MonadTrans, lift)
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix
import {-# SOURCE #-} Quasar.Resources.Disposer


class Monad m => MonadAwait m where
  -- | Wait until a future is completed and then return it's value.
  --
  -- Throws an exception if the future fails with an exception.
  await :: ToFuture e r a => a -> m r

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait IO where
  await f = do
    x <- atomically (readFuture f) `catch`
      \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait
    either (throwIO . exToException) pure x


instance {-# OVERLAPPABLE #-} (MonadTrans t, MonadAwait m, Monad (t m)) => MonadAwait (t m) where
  await = lift . await


type FutureCallback e a = Either (Ex e) a -> STMc NoRetry '[] ()
type SafeFutureCallback a = a -> STMc NoRetry '[] ()

type ToFuture :: [Type] -> Type -> Type -> Constraint
class ToFuture e r a | a -> e, a -> r where
  toFuture :: a -> Future e r
  default toFuture :: IsFuture e r a => a -> Future e r
  toFuture = Future

class ToFuture e r a => IsFuture e r a | a -> e, a -> r where
  {-# MINIMAL readFuture#, readOrAttachToFuture# #-}

  -- | Read the value from a future or block until it is available.
  --
  -- For the lifted variant see `readFuture`.
  --
  -- The implementation of `readFuture#` MUST NOT directly or indirectly
  -- complete a future. Only working with `TVar`s is guaranteed to be safe.
  readFuture# :: a -> STMc Retry '[] (Either (Ex e) r)

  -- | If the future is already completed, the value is returned in a `Right`.
  -- Otherwise the callback is attached to the future and will be called once
  -- the future is completed.
  --
  -- The resulting `TDisposer` can be used to deregister the callback.
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
  readOrAttachToFuture# :: a -> FutureCallback e r -> STMc NoRetry '[] (Either TDisposer (Either (Ex e) r))

  mapFuture# :: (r -> r2) -> a -> Future e r2
  mapFuture# f = Future . MappedFuture f . toFuture

  cacheFuture# :: a -> STMc NoRetry '[] (Future e r)
  cacheFuture# f = Future <$> newCachedFuture (toFuture f)


readFuture :: (ToFuture e r a, MonadSTMc Retry '[] m) => a -> m (Either (Ex e) r)
readFuture x = liftSTMc $ readFuture# (toFuture x)

readSafeFuture :: (ToFuture '[] r a, MonadSTMc Retry '[] m) => a -> m r
readSafeFuture f = liftSTMc do
  readFuture# (toFuture f) <&> \case
    Left ex -> absurdEx ex
    Right x -> x

readOrAttachToFuture :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback e r -> m (Either TDisposer (Either (Ex e) r))
readOrAttachToFuture x callback = liftSTMc $ readOrAttachToFuture# (toFuture x) callback

readOrAttachToSafeFuture :: (ToFuture '[] r a, MonadSTMc NoRetry '[] m) => a -> SafeFutureCallback r -> m (Either TDisposer r)
readOrAttachToSafeFuture fx callback = do
  r <- liftSTMc $ readOrAttachToFuture# (toFuture fx) \case
    Left ex -> absurdEx ex
    Right x -> callback x
  pure (either absurdEx id <$> r)

-- | Variant of `readOrAttachToFuture` that does not allow to detach the
-- callback.
readOrAttachToFuture_ :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback e r -> m (Maybe (Either (Ex e) r))
-- TODO disposer is dropped, revisit later
readOrAttachToFuture_ x callback = either (const Nothing) Just <$> readOrAttachToFuture x callback

-- | Will call the callback immediately if the future is already completed.
callOnceCompleted :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback e r -> m TDisposer
callOnceCompleted future callback = liftSTMc do
  readOrAttachToFuture future callback >>= \case
    Left disposer -> pure disposer
    Right value -> mempty <$ callback value

-- | Will call the callback immediately if the future is already completed.
callOnceCompletedSafe :: (ToFuture '[] r a, MonadSTMc NoRetry '[] m) => a -> SafeFutureCallback r -> m TDisposer
callOnceCompletedSafe future callback = liftSTMc do
  readOrAttachToSafeFuture future callback >>= \case
    Left disposer -> pure disposer
    Right value -> mempty <$ callback value

-- | Variant of `callOnceCompleted` that does not allow to detach the callback.
callOnceCompleted_ :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> FutureCallback e r -> m ()
-- TODO disposer is dropped, revisit later
callOnceCompleted_ future callback = void $ callOnceCompleted future callback

-- | Variant of `callOnceCompletedSafe` that does not allow to detach the callback.
callOnceCompletedSafe_ :: (ToFuture '[] r a, MonadSTMc NoRetry '[] m) => a -> SafeFutureCallback r -> m ()
-- TODO disposer is dropped, revisit later
callOnceCompletedSafe_ future callback = void $ callOnceCompletedSafe future callback

mapFuture :: ToFuture e r a => (r -> r2) -> a -> Future e r2
mapFuture f future = mapFuture# f (toFuture future)

cacheFuture :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> m (Future e r)
cacheFuture f = liftSTMc $ cacheFuture# (toFuture f)


-- | Returns the result (in a `Just`) when the future is completed and returns
-- `Nothing` otherwise.
peekFuture :: (ToFuture e r a, MonadSTMc NoRetry '[] m) => a -> m (Maybe (Either (Ex e) r))
peekFuture future = orElseNothing (readFuture# (toFuture future))

-- | Returns the result (in a `Just`) when the future is completed and returns
-- `Nothing` otherwise.
peekFutureIO :: (ToFuture e r a, MonadIO m) => a -> m (Maybe (Either (Ex e) r))
peekFutureIO future = atomically $ peekFuture future


type Future :: [Type] -> Type -> Type
data Future e r = forall a. IsFuture e r a => Future a


instance Functor (Future e) where
  fmap f x = toFuture (MappedFuture f x)

instance Applicative (Future e) where
  pure x = constFuture (Right x)
  liftA2 f x y = toFuture (LiftA2Future f x y)

instance Monad (Future e) where
  fx >>= fn = toFuture (BindFuture fx fn)


instance ToFuture e a (Future e a) where
  toFuture = id

instance IsFuture e a (Future e a) where
  readFuture# (Future x) = readFuture# x
  readOrAttachToFuture# (Future x) = readOrAttachToFuture# x
  mapFuture# f (Future x) = mapFuture# f x
  cacheFuture# (Future x) = cacheFuture# x

-- TODO
--instance MonadAwait (Future e) where
--  await = toFuture

instance Semigroup a => Semigroup (Future e a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Future e a) where
  mempty = pure mempty

instance (Exception e, e :< exceptions) => Throw e (Future exceptions) where
  throwC ex = constFuture (Left (toEx ex))

instance MonadThrowEx (Future exceptions) where
  unsafeThrowEx = constFuture . Left . unsafeToEx @exceptions

instance SomeException :< exceptions => MonadThrow (Future exceptions) where
  throwM = throwC . toException

instance (SomeException :< exceptions, Exception (Ex exceptions)) => MonadCatch (Future exceptions) where
  catch x f = toFuture $ CatchFuture x \ex ->
    case fromException (toException ex) of
      Just matched -> toFuture (f matched)
      Nothing -> throwFuture ex

instance SomeException :< exceptions => MonadFail (Future exceptions) where
  fail = throwM . userError

relaxFuture :: sub :<< super => Future sub a -> Future super a
relaxFuture f = toFuture $ CatchFuture f (\ex -> constFuture (Left (relaxEx ex)))

throwFuture :: Ex e -> Future e a
throwFuture = constFuture . Left


newtype ConstFuture e a = ConstFuture (Either (Ex e) a)

instance ToFuture e a (ConstFuture e a)

instance IsFuture e a (ConstFuture e a) where
  readFuture# (ConstFuture x) = pure x
  readOrAttachToFuture# (ConstFuture x) _ = pure (Right x)
  mapFuture# f (ConstFuture x) = toFuture (ConstFuture (f <$> x))
  cacheFuture# f = pure (toFuture f)

constFuture :: Either (Ex e) a -> Future e a
constFuture = toFuture . ConstFuture

data MappedFuture e a = forall b. MappedFuture (b -> a) (Future e b)

instance ToFuture e a (MappedFuture e a)

instance IsFuture e a (MappedFuture e a) where
  readFuture# (MappedFuture f future) = f <<$>> readFuture# future
  readOrAttachToFuture# (MappedFuture f future) callback =
    fmap f <<$>> readOrAttachToFuture# future (callback . fmap f)
  mapFuture# f1 (MappedFuture f2 future) =
    toFuture (MappedFuture (f1 . f2) future)


data LiftA2Future e a =
  forall b c. LiftA2Future (b -> c -> a) (Future e b) (Future e c)

data LiftA2State e a b = LiftA2Initial | LiftA2Left a | LiftA2Right (Either (Ex e) b) | LiftA2Done

instance ToFuture e a (LiftA2Future e a)

instance IsFuture e a (LiftA2Future e a) where
  readFuture# (LiftA2Future fn fx fy) = do
    readFuture# fx >>= \case
      Left ex -> pure (Left ex)
      Right x -> fn x <<$>> readFuture# fy

  readOrAttachToFuture# (LiftA2Future fn fx fy) callback =
    mfixExtra \s -> do
      var <- newTVar s
      r1 <- readOrAttachToFuture# fx \case
        Left ex -> dispatchEx var ex
        Right x -> readTVar var >>= \case
          LiftA2Initial -> writeTVar var (LiftA2Left x)
          LiftA2Right y -> dispatch var x y
          _ -> unreachableCodePath

      case r1 of
        Left d1 -> do
          r2 <- readOrAttachToFuture# fy \y -> do
            readTVar var >>= \case
              LiftA2Initial -> writeTVar var (LiftA2Right y)
              LiftA2Left x -> dispatch var x y
              _ -> unreachableCodePath
          pure case r2 of
            Right v2 -> (Left d1, LiftA2Right v2)
            Left d2 -> (Left (d1 <> d2), LiftA2Initial)
        Right (Left ex) -> pure (Right (Left ex), LiftA2Done)
        Right (Right x) -> do
          r2 <- readOrAttachToFuture# fy \y -> dispatch var x y
          pure case r2 of
            Right (Left ex) -> (Right (Left ex), LiftA2Done)
            Right (Right v2) -> (Right (Right (fn x v2)), LiftA2Done)
            Left d2 -> (Left d2, LiftA2Left x)
    where
      dispatch var x ry = do
        writeTVar var LiftA2Done
        case ry of
          Left ex -> callback (Left ex)
          Right y -> callback (Right (fn x y))
      dispatchEx var ex = do
        writeTVar var LiftA2Done
        callback (Left ex)

  mapFuture# f (LiftA2Future fn fx fy) =
    toFuture (LiftA2Future (\x y -> f (fn x y)) fx fy)


data BindFuture e a = forall b. BindFuture (Future e b) (b -> Future e a)

instance ToFuture e a (BindFuture e a)

instance IsFuture e a (BindFuture e a) where
  readFuture# (BindFuture fx fn) =
    readFuture# fx >>= \case
      Left ex -> pure (Left ex)
      Right x -> readFuture# (fn x)

  readOrAttachToFuture# (BindFuture fx fn) callback = do
    disposerVar <- newTVar Nothing
    dyWrapper <- newUnmanagedTDisposer do
      mapM_ disposeTDisposer =<< swapTVar disposerVar Nothing
    rx <- readOrAttachToFuture# fx \case
      Left ex -> callback (Left ex)
      Right x -> do
        ry <- readOrAttachToFuture# (fn x) \y -> do
          callback y
          disposeTDisposer dyWrapper
        case ry of
          Left dy -> do
            writeTVar disposerVar (Just dy)
            callOnceCompletedSafe_ dy \() ->
              -- This is not a loop since disposing a TDisposer is reentrant-safe
              disposeTDisposer dyWrapper
          Right y -> do
            callback y
            disposeTDisposer dyWrapper
    case rx of
      Left dx -> pure (Left (dx <> dyWrapper))
      -- LHS already completed, so trivially defer to RHS
      Right (Left ex) -> pure (Right (Left ex))
      Right (Right x) -> readOrAttachToFuture# (fn x) callback


  mapFuture# f (BindFuture fx fn) = toFuture (BindFuture fx (fmap f . fn))


data CatchFuture e a = forall e2. CatchFuture (Future e2 a) (Ex e2 -> Future e a)

instance ToFuture e a (CatchFuture e a)

instance IsFuture e a (CatchFuture e a) where
  readFuture# (CatchFuture fx fn) =
    readFuture# fx >>= \case
      Left ex -> readFuture# (fn ex)
      Right x -> pure (Right x)

  readOrAttachToFuture# (CatchFuture fx fn) callback = do
    disposerVar <- newTVar Nothing
    dyWrapper <- newUnmanagedTDisposer do
      mapM_ disposeTDisposer =<< swapTVar disposerVar Nothing
    rx <- readOrAttachToFuture# fx \case
      Left ex -> do
        ry <- readOrAttachToFuture# (fn ex) \y -> do
          callback y
          disposeTDisposer dyWrapper
        case ry of
          Left dy -> do
            writeTVar disposerVar (Just dy)
            callOnceCompletedSafe_ dy \() ->
              -- This is not a loop since disposing a TDisposer is reentrant-safe
              disposeTDisposer dyWrapper
          Right y -> do
            callback y
            disposeTDisposer dyWrapper
      Right x -> callback (Right x)
    case rx of
      Left dx -> pure (Left (dx <> dyWrapper))
      Right (Left ex) -> readOrAttachToFuture# (fn ex) callback
      -- LHS already completed, so trivially defer to RHS
      Right (Right x) -> pure (Right (Right x))



newtype CachedFuture e a = CachedFuture (TVar (CacheState e a))
data CacheState e a
  = CacheIdle (Future e a)
  | CacheAttached (Future e a) TDisposer (CallbackRegistry (Either (Ex e) a))
  | Cached (Either (Ex e) a)

newCachedFuture :: Future e a -> STMc NoRetry '[] (CachedFuture e a)
newCachedFuture f = CachedFuture <$> newTVar (CacheIdle f)

instance ToFuture e a (CachedFuture e a)

instance IsFuture e a (CachedFuture e a) where
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

removeCacheListener :: CachedFuture e a -> STMc NoRetry '[] ()
removeCacheListener (CachedFuture var) = do
  readTVar var >>= \case
    CacheIdle _ -> unreachableCodePath
    CacheAttached future disposer _callbackRegistry -> do
      writeTVar var (CacheIdle future)
      disposeTDisposer disposer
    Cached _ -> pure ()

fulfillCacheValue :: CachedFuture e a -> Either (Ex e) a -> STMc NoRetry '[] ()
fulfillCacheValue (CachedFuture var) value =
  swapTVar var (Cached value) >>= \case
    CacheIdle _ -> pure ()
    CacheAttached _ disposer registry -> do
      disposeTDisposer disposer
      callCallbacks registry value
    Cached _ -> pure ()

readCacheUpstreamFuture :: CachedFuture e a -> Future e a -> STMc Retry '[] (Either (Ex e) a)
readCacheUpstreamFuture cache future = do
  value <- readFuture# future
  liftSTMc $ fulfillCacheValue cache value
  pure value


type FutureEx :: [Type] -> Type -> Type
type FutureEx exceptions a = Future exceptions a


-- ** Promise

-- | A value container that can be written once and implements `IsFuture`.
newtype Promise a = Promise (TVar (Either (CallbackRegistry a) a))

type PromiseEx exceptions a = Promise (Either (Ex exceptions) a)

instance ToFuture '[] a (Promise a)

instance IsFuture '[] a (Promise a) where
  readFuture# (Promise var) =
    readTVar var >>= \case
      Left _ -> retry
      Right value -> pure (Right value)

  readOrAttachToFuture# (Promise var) callback =
    readTVar var >>= \case
      Right value -> pure (Right (Right value))
      Left registry ->
        -- NOTE Using mfix to get the disposer is a safe because the registered
        -- method won't be called immediately.
        -- Modifying the callback to deregister itself is an inefficient hack
        -- that could be improved by writing a custom registry.
        Left <$> mfix \disposer -> do
          registerCallback registry \value -> do
            callback (Right value)
            disposeTDisposer disposer

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

execToPromiseEx :: PromiseEx exceptions a -> STMc NoRetry exceptions a -> STMc NoRetry '[] ()
execToPromiseEx promise fn = tryFulfillPromise_ promise =<< tryExSTMc fn

toFutureEx :: ToFuture '[] (Either (Ex e) a) b => b -> Future e a
toFutureEx f = relaxFuture (toFuture f) >>= constFuture


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


-- ** Awaiting multiple futures

data AnyFuture e a = AnyFuture [Future e a] (TVar (Maybe (Either (Ex e) a)))

instance ToFuture e a (AnyFuture e a)

instance IsFuture e a (AnyFuture e a) where
  readFuture# (AnyFuture fs var) = do
    readTVar var >>= \case
      Just value -> pure value
      Nothing -> do
        value <- foldr (orElseC . readFuture#) retry fs
        writeTVar var (Just value)
        pure value

  readOrAttachToFuture# (AnyFuture futures var) callback = do
    readTVar var >>= \case
      Just value -> pure (Right value)
      Nothing -> go futures []
    where
      go :: [Future e a] -> [TDisposer] -> STMc NoRetry '[] (Either TDisposer (Either (Ex e) a))
      go [] acc = pure (Left (mconcat acc))
      go (f : fs) acc = do
        readOrAttachToFuture# f internalCallback >>= \case
          Left disposer -> go fs (disposer : acc)
          Right value -> do
            mapM_ disposeTDisposer acc
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
anyFuture :: MonadSTMc NoRetry '[] m => [Future e r] -> m (Future e r)
anyFuture fs = toFuture <$> (AnyFuture fs <$> newTVar Nothing)

-- | Like `awaitAny` with two futures.
any2Future :: MonadSTMc NoRetry '[] m => Future e r -> Future e r -> m (Future e r)
any2Future x y = anyFuture [toFuture x, toFuture y]

-- | Completes as soon as either future completes.
eitherFuture :: MonadSTMc NoRetry '[] m => Future e a -> Future e b -> m (Future e (Either a b))
eitherFuture x y = any2Future (Left <$> x) (Right <$> y)
