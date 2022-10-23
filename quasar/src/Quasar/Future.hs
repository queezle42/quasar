module Quasar.Future (
  -- * MonadAwait
  MonadAwait,
  MonadAwait'(..),
  peekFuture,
  peekFutureSTM,
  awaitSTM,

  -- * Future
  IsFuture,
  IsFuture'(toFuture),
  Future,
  Future',
  successfulFuture,
  failedFuture,
  completedFuture,

  -- * Future helpers
  afix,
  afix_,
  afixExtra,
  awaitSuccessOrFailure,

  -- ** Awaiting multiple awaitables
  awaitAny,
  awaitAny2,
  awaitEither,

  -- * Promise
  Promise,

  -- ** Manage `Promise`s in IO
  newPromise,
  fulfillPromise,
  breakPromise,
  completePromise,

  tryFulfillPromise,
  tryBreakPromise,
  tryCompletePromise,

  -- ** Manage `Promise`s in STM
  newPromiseSTM,
  fulfillPromiseSTM,
  breakPromiseSTM,
  completePromiseSTM,
  peekPromiseSTM,

  tryFulfillPromiseSTM,
  tryBreakPromiseSTM,
  tryCompletePromiseSTM,

  -- ** Unsafe implementation helpers
  unsafeSTMToFuture,
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


class MonadFix m => MonadAwait' t m where
  -- | Wait until an awaitable is completed and then return it's value (or throw an exception).
  await :: IsFuture' t r a => a -> m r

type MonadAwait = MonadAwait' CanThrow

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait' CanThrow IO where
  await (toFuture -> Future x) =
    atomically' x
      `catch`
        \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

-- | `awaitSTM` exists as an explicit alternative to a `Future STM`-instance, to prevent code which creates- and
-- then awaits resources without knowing it's running in STM (which would block indefinitely when run in STM).
awaitSTM :: MonadSTM' CanRetry t m => IsFuture' t r a => a -> m r
awaitSTM (toFuture -> Future x) = liftSTM' x

instance MonadAwait' t m => MonadAwait' t (ReaderT a m) where
  await = lift . await

instance (MonadAwait' t m, Monoid a) => MonadAwait' t (WriterT a m) where
  await = lift . await

instance MonadAwait' t m => MonadAwait' t (StateT a m) where
  await = lift . await

instance (MonadAwait' t m, Monoid w) => MonadAwait' t (RWST r w s m) where
  await = lift . await

instance MonadAwait' t m => MonadAwait' t (MaybeT m) where
  await = lift . await



-- | Returns the result (in a `Just`) when the future is completed, throws an `Exception` when the future is
-- failed and returns `Nothing` otherwise.
peekFuture :: MonadIO m => Future r -> m (Maybe r)
peekFuture future = atomically $ peekFutureSTM future

-- | Returns the result (in a `Just`) when the future is completed, throws an `Exception` when the future is
-- failed and returns `Nothing` otherwise.
peekFutureSTM :: MonadSTM' r CanThrow m => Future a -> m (Maybe a)
peekFutureSTM future = (Just <$> awaitSTM future) `orElse'` pure Nothing


class IsFuture' (t :: ThrowMode) r a | a -> r, a -> t where
  toFuture :: a -> Future' t r

type IsFuture = IsFuture' CanThrow


unsafeSTMToFuture :: STM a -> Future a
unsafeSTMToFuture f = Future (liftSTM f)

unsafeSTM'ToFuture :: STM' CanRetry t a -> Future' t a
unsafeSTM'ToFuture = Future

unsafeAwaitSTM :: MonadAwait m => STM a -> m a
unsafeAwaitSTM = await . unsafeSTMToFuture

-- TODO relax CanThrow constraint by reworking MonadAwait
unsafeAwaitSTM' :: MonadAwait m => STM' CanRetry CanThrow a -> m a
unsafeAwaitSTM' = await . unsafeSTM'ToFuture


newtype Future' t a = Future (STM' CanRetry t a)
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadFix,
    Alternative,
    MonadPlus
    )

type Future = Future' CanThrow

deriving newtype instance MonadThrow Future
deriving newtype instance MonadCatch Future


instance IsFuture' t a (Future' t a) where
  toFuture = id

instance MonadAwait' t (Future' t) where
  await = toFuture

instance Semigroup r => Semigroup (Future r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Future r) where
  mempty = pure mempty

instance MonadFail (Future' CanThrow) where
  fail = throwM . userError




completedFuture :: Either SomeException r -> Future r
completedFuture = either throwM pure

-- | Alias for `pure`.
successfulFuture :: r -> Future r
successfulFuture = pure

failedFuture :: SomeException -> Future r
failedFuture = throwM



-- ** Promise

-- | The default implementation for an `Future` that can be fulfilled later.
newtype BasicPromise r = BasicPromise (TMVar r)
newtype Promise r = Promise (BasicPromise (Either SomeException r))

--instance IsFuture' t r (Promise t r) where
--  toFuture (Promise var) = unsafeSTMToFuture $ either throwM pure =<< readTMVar var

instance IsFuture' CanThrow r (Promise r) where
  toFuture (Promise promise) = either failedFuture pure =<< awaitBasicPromise promise

instance IsFuture' NoThrow r (BasicPromise r) where
  toFuture (BasicPromise var) = unsafeSTM'ToFuture $ readTMVar var

awaitBasicPromise :: MonadAwait m => BasicPromise a -> m a
awaitBasicPromise (BasicPromise var) = unsafeAwaitSTM' (readTMVar var)


newPromiseSTM :: MonadSTM' r t m => m (Promise a)
newPromiseSTM = Promise . BasicPromise <$> newEmptyTMVar

newPromise :: MonadIO m => m (Promise r)
newPromise = liftIO $ Promise . BasicPromise <$> newEmptyTMVarIO


completePromiseSTM :: MonadSTM' r CanThrow m => Promise a -> Either SomeException a -> m ()
completePromiseSTM var result = do
  success <- tryCompletePromiseSTM var result
  unless success $ throwSTM PromiseAlreadyCompleted

tryCompletePromiseSTM :: MonadSTM' r t m => Promise a -> Either SomeException a -> m Bool
tryCompletePromiseSTM (Promise (BasicPromise var)) = tryPutTMVar var


peekPromiseSTM :: MonadSTM' r CanThrow m => Promise a -> m (Maybe a)
peekPromiseSTM (Promise (BasicPromise var)) = mapM (either throwSTM pure) =<< tryReadTMVar var


fulfillPromise :: MonadIO m => Promise a -> a -> m ()
fulfillPromise var result = atomically $ fulfillPromiseSTM var result

fulfillPromiseSTM :: MonadSTM' r CanThrow m => Promise a -> a -> m ()
fulfillPromiseSTM var result = completePromiseSTM var (Right result)

breakPromise :: (Exception e, MonadIO m) => Promise a -> e -> m ()
breakPromise var result = atomically $ breakPromiseSTM var result

breakPromiseSTM :: (Exception e, MonadSTM' r CanThrow m) => Promise a -> e -> m ()
breakPromiseSTM var result = completePromiseSTM var (Left (toException result))

completePromise :: MonadIO m => Promise a -> Either SomeException a -> m ()
completePromise var result = atomically $ completePromiseSTM var result


tryFulfillPromise :: MonadIO m => Promise a -> a -> m Bool
tryFulfillPromise var result = atomically $ tryFulfillPromiseSTM var result

tryFulfillPromiseSTM :: MonadSTM' r t m => Promise a -> a -> m Bool
tryFulfillPromiseSTM var result = tryCompletePromiseSTM var (Right result)

tryBreakPromise :: (Exception e, MonadIO m) => Promise a -> e -> m Bool
tryBreakPromise var result = atomically $ tryBreakPromiseSTM var result

tryBreakPromiseSTM :: MonadSTM' r t m => Exception e => Promise a -> e -> m Bool
tryBreakPromiseSTM var result = tryCompletePromiseSTM var (Left (toException result))

tryCompletePromise :: MonadIO m => Promise a -> Either SomeException a -> m Bool
tryCompletePromise var result = atomically $ tryCompletePromiseSTM var result



-- * Utility functions

-- | Await success or failure of another awaitable, then return `()`.
awaitSuccessOrFailure :: (IsFuture r a, MonadAwait m) => a -> m ()
awaitSuccessOrFailure = await . fireAndForget . toFuture
  where
    fireAndForget :: MonadCatch m => m r -> m ()
    fireAndForget x = void x `catchAll` const (pure ())

afix :: (MonadIO m, MonadCatch m) => (Future a -> m a) -> m a
afix action = do
  var <- newPromise
  catchAll
    do
      result <- action (toFuture var)
      fulfillPromise var result
      pure result
    \ex -> do
      breakPromise var ex
      throwM ex

afix_ :: (MonadIO m, MonadCatch m) => (Future a -> m a) -> m ()
afix_ = void . afix

afixExtra :: (MonadIO m, MonadCatch m) => (Future a -> m (r, a)) -> m r
afixExtra action = do
  var <- newPromise
  catchAll
    do
      (result, fixResult) <- action (toFuture var)
      fulfillPromise var fixResult
      pure result
    \ex -> do
      breakPromise var ex
      throwM ex


-- ** Awaiting multiple awaitables


-- | Completes as soon as either awaitable completes.
awaitEither :: MonadAwait m => Future ra -> Future rb -> m (Either ra rb)
awaitEither (Future x) (Future y) = unsafeAwaitSTM $ liftSTM' (eitherSTM x y)

-- | Helper for `awaitEither`
eitherSTM :: STM' CanRetry t a -> STM' CanRetry t b -> STM' CanRetry t (Either a b)
eitherSTM x y = fmap Left x `orElse'` fmap Right y


-- Completes as soon as any awaitable in the list is completed and then returns the left-most completed result
-- (or exception).
awaitAny :: MonadAwait m => [Future r] -> m r
awaitAny xs = unsafeAwaitSTM $ anySTM $ awaitSTM <$> xs

-- | Helper for `awaitAny`
anySTM :: [STM a] -> STM a
anySTM [] = retry
anySTM (x:xs) = x `orElse` anySTM xs


-- | Like `awaitAny` with two awaitables.
awaitAny2 :: MonadAwait m => Future r -> Future r -> m r
awaitAny2 x y = awaitAny [toFuture x, toFuture y]
