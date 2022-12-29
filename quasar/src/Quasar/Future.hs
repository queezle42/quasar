module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureSTM,
  awaitSTM,

  -- * Future
  IsFuture(toFuture),
  Future,

  -- * Future helpers
  afix,
  afix_,
  afixExtra,

  -- ** Awaiting multiple awaitables
  awaitAny,
  awaitAny2,
  awaitEither,

  -- * Promise
  Promise,

  -- ** Manage `Promise`s in IO
  newPromise,
  fulfillPromise,
  tryFulfillPromise,

  -- ** Manage `Promise`s in STM
  newPromiseSTM,
  fulfillPromiseSTM,
  tryFulfillPromiseSTM,
  peekPromiseSTM,

  -- * Exception variants
  FutureE,
  toFutureE,
  PromiseE,

  -- ** Unsafe implementation helpers
  unsafeSTMcToFuture,
  unsafeSTMToFutureE,
  unsafeAwaitSTMc,
  unsafeAwaitSTM,
) where

import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Writer (WriterT)
import Control.Monad.State (StateT)
import Control.Monad.RWS (RWST)
import Control.Monad.Trans.Maybe
import Quasar.Prelude
import Quasar.Exceptions


class MonadFix m => MonadAwait m where
  -- | Wait until a future is completed and then return it's value.
  await :: IsFuture r a => a -> m r

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait IO where
  await (toFuture -> Future x) =
    atomicallyC $ liftSTMc x
      `catch`
        \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

-- | `awaitSTM` exists as an explicit alternative to a `Future STM`-instance, to prevent code which creates- and
-- then awaits resources without knowing it's running in STM (which would block indefinitely when run in STM).
awaitSTM :: MonadSTMc '[Retry] m => IsFuture r a => a -> m r
awaitSTM (toFuture -> Future x) = liftSTMc x

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



-- | Returns the result (in a `Just`) when the future is completed, throws an `Exception` when the future is
-- failed and returns `Nothing` otherwise.
peekFuture :: MonadIO m => Future r -> m (Maybe r)
peekFuture future = atomically $ peekFutureSTM future

-- | Returns the result (in a `Just`) when the future is completed, throws an `Exception` when the future is
-- failed and returns `Nothing` otherwise.
peekFutureSTM :: MonadSTMc '[] m => Future a -> m (Maybe a)
peekFutureSTM future = orElseC @'[Retry] (Just <$> awaitSTM future) (pure Nothing)


class IsFuture r a | a -> r where
  toFuture :: a -> Future r


unsafeSTMToFutureE :: STM a -> FutureE a
unsafeSTMToFutureE = FutureE

unsafeSTMcToFuture :: STMc '[Retry] a -> Future a
unsafeSTMcToFuture = Future

unsafeAwaitSTMc :: MonadAwait m => STMc '[Retry] a -> m a
unsafeAwaitSTMc = await . unsafeSTMcToFuture

unsafeAwaitSTM :: MonadAwait m => STM a -> m (Either SomeException a)
unsafeAwaitSTM = await . unsafeSTMToFutureE


newtype Future a = Future (STMc '[Retry] a)
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadFix,
    Alternative,
    MonadPlus
    )


instance IsFuture a (Future a) where
  toFuture = id

instance MonadAwait Future where
  await = toFuture

instance Semigroup a => Semigroup (Future a) where
  x <> y = liftA2 (<>) x y

instance Monoid a => Monoid (Future a) where
  mempty = pure mempty


newtype FutureE a = FutureE (STM a)
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadFix,
    Alternative,
    MonadPlus,
    MonadThrow,
    MonadCatch
    )

instance IsFuture (Either SomeException a) (FutureE a) where
  toFuture (FutureE f) = Future (tryAllSTMc @'[Retry, ThrowAny] (liftSTM f))


instance MonadAwait FutureE where
  await :: IsFuture r a => a -> FutureE r
  await f = FutureE (awaitSTM (toFuture f))

toFutureE :: IsFuture (Either SomeException r) a => a -> FutureE r
toFutureE x = FutureE (either throwM pure =<< awaitSTM (toFuture x))



-- ** Promise

-- | The default implementation for an `Future` that can be fulfilled later.
newtype Promise a = Promise (TMVar a)

type PromiseE a = Promise (Either SomeException a)

--instance IsFuture' t r (Promise t r) where
--  toFuture (Promise var) = unsafeSTMToFuture $ either throwM pure =<< readTMVar var

instance IsFuture a (Promise a) where
  toFuture (Promise var) = unsafeAwaitSTMc (readTMVar var)

newPromiseSTM :: MonadSTMc '[] m => m (Promise a)
newPromiseSTM = Promise <$> newEmptyTMVar

newPromise :: MonadIO m => m (Promise a)
newPromise = liftIO $ Promise <$> newEmptyTMVarIO


peekPromiseSTM :: MonadSTMc '[] m => Promise a -> m (Maybe a)
peekPromiseSTM (Promise var) = tryReadTMVar var


fulfillPromise :: MonadIO m => Promise a -> a -> m ()
fulfillPromise var result = atomically $ fulfillPromiseSTM var result

fulfillPromiseSTM :: MonadSTMc '[Throw PromiseAlreadyCompleted] m => Promise a -> a -> m ()
fulfillPromiseSTM var result = do
  success <- tryFulfillPromiseSTM var result
  unless success $ throwC PromiseAlreadyCompleted


tryFulfillPromise :: MonadIO m => Promise a -> a -> m Bool
tryFulfillPromise var result = atomically $ tryFulfillPromiseSTM var result

tryFulfillPromiseSTM :: MonadSTMc '[] m => Promise a -> a -> m Bool
tryFulfillPromiseSTM (Promise var) result = tryPutTMVar var result



-- * Utility functions

afix :: (MonadIO m, MonadCatch m) => (FutureE a -> m a) -> m a
afix action = do
  var <- newPromise
  catchAll
    do
      result <- action (toFutureE var)
      fulfillPromise var (Right result)
      pure result
    \ex -> do
      fulfillPromise var (Left ex)
      throwM ex

afix_ :: (MonadIO m, MonadCatch m) => (FutureE a -> m a) -> m ()
afix_ = void . afix

afixExtra :: (MonadIO m, MonadCatch m) => (FutureE a -> m (r, a)) -> m r
afixExtra action = do
  var <- newPromise
  catchAll
    do
      (result, fixResult) <- action (toFutureE var)
      fulfillPromise var (Right fixResult)
      pure result
    \ex -> do
      fulfillPromise var (Left ex)
      throwM ex


-- ** Awaiting multiple awaitables


-- | Completes as soon as either awaitable completes.
awaitEither :: MonadAwait m => Future ra -> Future rb -> m (Either ra rb)
awaitEither (Future x) (Future y) = unsafeAwaitSTMc (eitherSTM x y)

-- | Helper for `awaitEither`
eitherSTM :: STMc '[Retry] a -> STMc '[Retry] b -> STMc '[Retry] (Either a b)
eitherSTM x y = fmap Left x `orElseC` fmap Right y


-- Completes as soon as any awaitable in the list is completed and then returns the left-most completed result
-- (or exception).
awaitAny :: MonadAwait m => [Future r] -> m r
awaitAny xs = unsafeAwaitSTMc $ anySTM $ awaitSTM <$> xs

-- | Helper for `awaitAny`
anySTM :: [STMc '[Retry] a] -> STMc '[Retry] a
anySTM [] = retry
anySTM (x:xs) = x `orElseC` anySTM xs


-- | Like `awaitAny` with two awaitables.
awaitAny2 :: MonadAwait m => Future r -> Future r -> m r
awaitAny2 x y = awaitAny [toFuture x, toFuture y]


-- TODO export; use for awaitEither and awaitAny
cacheFuture :: forall a m. MonadSTMc '[] m => Future a -> m (Future a)
cacheFuture f = do
  cache <- newEmptyTMVar
  pure (unsafeAwaitSTMc (queryCache cache))
  where
    queryCache :: TMVar a -> STMc '[Retry] a
    queryCache cache = do
      tryReadTMVar cache >>= \case
        Just result -> pure result
        Nothing -> do
          result <- awaitSTM f
          putTMVar cache result
          pure result
