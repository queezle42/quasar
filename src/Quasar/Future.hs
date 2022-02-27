module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureSTM,
  awaitSTM,

  -- * Future
  IsFuture(toFuture),
  Future,
  successfulFuture,
  failedFuture,
  completedFuture,

  -- * Future helpers
  afix,
  afix_,
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

import Control.Concurrent.STM
import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Writer (WriterT)
import Control.Monad.State (StateT)
import Control.Monad.RWS (RWST)
import Control.Monad.Trans.Maybe
import Quasar.Prelude
import Quasar.Exceptions


class (MonadCatch m, MonadPlus m, MonadFix m) => MonadAwait m where
  -- | Wait until an awaitable is completed and then return it's value (or throw an exception).
  await :: IsFuture r a => a -> m r

data BlockedIndefinitelyOnAwait = BlockedIndefinitelyOnAwait
  deriving stock Show

instance Exception BlockedIndefinitelyOnAwait where
  displayException BlockedIndefinitelyOnAwait = "Thread blocked indefinitely in an 'await' operation"


instance MonadAwait IO where
  await (toFuture -> Future x) =
    atomically x
      `catch`
        \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

-- | `awaitSTM` exists as an explicit alternative to a `Future STM`-instance, to prevent code which creates- and
-- then awaits resources without knowing it's running in STM (which would block indefinitely when run in STM).
awaitSTM :: IsFuture r a => a -> STM r
awaitSTM (toFuture -> Future x) =
  x `catch` \BlockedIndefinitelyOnSTM -> throwM BlockedIndefinitelyOnAwait

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



-- | Returns the result (in a `Just`) when the awaitable is completed, throws an `Exception` when the awaitable is
-- failed and returns `Nothing` otherwise.
peekFuture :: MonadIO m => Future r -> m (Maybe r)
peekFuture awaitable = liftIO $ atomically $ (Just <$> awaitSTM awaitable) `orElse` pure Nothing

-- | Returns the result (in a `Just`) when the awaitable is completed, throws an `Exception` when the awaitable is
-- failed and returns `Nothing` otherwise.
peekFutureSTM :: Future r -> STM (Maybe r)
peekFutureSTM awaitable = (Just <$> awaitSTM awaitable) `orElse` pure Nothing



class IsFuture r a | a -> r where
  toFuture :: a -> Future r





unsafeSTMToFuture :: STM a -> Future a
unsafeSTMToFuture = Future

unsafeAwaitSTM :: MonadAwait m => STM a -> m a
unsafeAwaitSTM = await . unsafeSTMToFuture


newtype Future r = Future (STM r)
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadThrow,
    MonadCatch,
    MonadFix,
    Alternative,
    MonadPlus
    )


instance IsFuture r (Future r) where
  toFuture = id

instance MonadAwait Future where
  await = toFuture

instance Semigroup r => Semigroup (Future r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Future r) where
  mempty = pure mempty

instance MonadFail Future where
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
newtype Promise r = Promise (TMVar (Either SomeException r))

instance IsFuture r (Promise r) where
  toFuture (Promise var) = unsafeSTMToFuture $ either throwM pure =<< readTMVar var


newPromiseSTM :: STM (Promise r)
newPromiseSTM = Promise <$> newEmptyTMVar

newPromise :: MonadIO m => m (Promise r)
newPromise = liftIO $ Promise <$> newEmptyTMVarIO


completePromiseSTM :: Promise a -> Either SomeException a -> STM ()
completePromiseSTM var result = do
  success <- tryCompletePromiseSTM var result
  unless success $ throwM PromiseAlreadyCompleted

tryCompletePromiseSTM :: Promise a -> Either SomeException a -> STM Bool
tryCompletePromiseSTM (Promise var) = tryPutTMVar var


peekPromiseSTM :: forall a. Promise a -> STM (Maybe a)
peekPromiseSTM (Promise var) = mapM (either throwM pure) =<< tryReadTMVar var


fulfillPromise :: MonadIO m => Promise a -> a -> m ()
fulfillPromise var result = liftIO $ atomically $ fulfillPromiseSTM var result

fulfillPromiseSTM :: Promise a -> a -> STM ()
fulfillPromiseSTM var result = completePromiseSTM var (Right result)

breakPromise :: (Exception e, MonadIO m) => Promise a -> e -> m ()
breakPromise var result = liftIO $ atomically $ breakPromiseSTM var result

breakPromiseSTM :: Exception e => Promise a -> e -> STM ()
breakPromiseSTM var result = completePromiseSTM var (Left (toException result))

completePromise :: MonadIO m => Promise a -> Either SomeException a -> m ()
completePromise var result = liftIO $ atomically $ completePromiseSTM var result



tryFulfillPromise :: MonadIO m => Promise a -> a -> m Bool
tryFulfillPromise var result = liftIO $ atomically $ tryFulfillPromiseSTM var result

tryFulfillPromiseSTM :: Promise a -> a -> STM Bool
tryFulfillPromiseSTM var result = tryCompletePromiseSTM var (Right result)

tryBreakPromise :: (Exception e, MonadIO m) => Promise a -> e -> m Bool
tryBreakPromise var result = liftIO $ atomically $ tryBreakPromiseSTM var result

tryBreakPromiseSTM :: Exception e => Promise a -> e -> STM Bool
tryBreakPromiseSTM var result = tryCompletePromiseSTM var (Left (toException result))

tryCompletePromise :: MonadIO m => Promise a -> Either SomeException a -> m Bool
tryCompletePromise var result = liftIO $ atomically $ tryCompletePromiseSTM var result



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


-- ** Awaiting multiple awaitables


-- | Completes as soon as either awaitable completes.
awaitEither :: MonadAwait m => Future ra -> Future rb -> m (Either ra rb)
awaitEither (Future x) (Future y) = unsafeAwaitSTM (eitherSTM x y)

-- | Helper for `awaitEither`
eitherSTM :: STM a -> STM b -> STM (Either a b)
eitherSTM x y = fmap Left x `orElse` fmap Right y


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
