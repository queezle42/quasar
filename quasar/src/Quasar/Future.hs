module Quasar.Future (
  -- * MonadAwait
  MonadAwait(..),
  peekFuture,
  peekFutureSTM,
  awaitSTM,

  -- * Future
  IsFuture(toFuture),
  IsFutureEx,
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
  FutureEx,
  toFutureEx,
  PromiseEx,

  -- * Caching
  cacheFuture,

  -- ** Unsafe implementation helpers
  unsafeSTMcToFuture,
  unsafeSTMToFutureEx,
  unsafeAwaitSTMc,
  unsafeAwaitSTM,
) where

import Control.Exception (BlockedIndefinitelyOnSTM(..))
import Control.Exception.Ex
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
awaitSTM :: MonadSTMc Retry '[] m => IsFuture r a => a -> m r
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
peekFutureSTM :: MonadSTMc NoRetry '[] m => Future a -> m (Maybe a)
peekFutureSTM future = orElseC @'[] (Just <$> awaitSTM future) (pure Nothing)


class IsFuture r a | a -> r where
  toFuture :: a -> Future r

type IsFutureEx exceptions r = IsFuture (Either (Ex exceptions) r)


-- | Only safe if the computation obeys the future laws.
unsafeSTMToFutureEx :: STM a -> FutureEx '[SomeException] a
unsafeSTMToFutureEx = FutureEx . liftSTM

-- | Only safe if the computation obeys the future laws.
unsafeSTMcToFuture :: STMc Retry '[] a -> Future a
unsafeSTMcToFuture = Future

unsafeAwaitSTMc :: MonadAwait m => STMc Retry '[] a -> m a
unsafeAwaitSTMc = await . unsafeSTMcToFuture

unsafeAwaitSTM :: MonadAwait m => STM a -> m (Either (Ex '[SomeException]) a)
unsafeAwaitSTM = await . unsafeSTMToFutureEx


newtype Future a = Future (STMc Retry '[] a)
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


type FutureEx :: [Type] -> Type -> Type
newtype FutureEx exceptions a = FutureEx (STMc Retry exceptions a)
  deriving newtype (
    Functor,
    Applicative,
    Monad,
    MonadFix,
    Alternative,
    MonadPlus,
    MonadThrow,
    MonadCatch,
    Throw e,
    ThrowEx
    )

instance IsFuture (Either (Ex exceptions) a) (FutureEx exceptions a) where
  toFuture (FutureEx f) = Future (tryExSTMc f)


instance MonadAwait (FutureEx exceptions) where
  await :: IsFuture r a => a -> FutureEx exceptions r
  await f = FutureEx (awaitSTM (toFuture f))

toFutureEx ::
  forall exceptions r a.
  (IsFuture (Either (Ex exceptions) r) a, ExceptionList exceptions) =>
  a -> FutureEx exceptions r
-- unsafeThrowEx is safe here and prevents an extra `ThrowForAll` constraint
toFutureEx x = FutureEx (either unsafeThrowEx pure =<< awaitSTM x)



-- ** Promise

-- | The default implementation for an `Future` that can be fulfilled later.
newtype Promise a = Promise (TMVar a)

type PromiseEx exceptions a = Promise (Either (Ex exceptions) a)

instance IsFuture a (Promise a) where
  toFuture (Promise var) = unsafeAwaitSTMc (readTMVar var)

newPromiseSTM :: MonadSTMc NoRetry '[] m => m (Promise a)
newPromiseSTM = Promise <$> newEmptyTMVar

newPromise :: MonadIO m => m (Promise a)
newPromise = liftIO $ Promise <$> newEmptyTMVarIO


peekPromiseSTM :: MonadSTMc NoRetry '[] m => Promise a -> m (Maybe a)
peekPromiseSTM (Promise var) = tryReadTMVar var


fulfillPromise :: MonadIO m => Promise a -> a -> m ()
fulfillPromise var result = atomically $ fulfillPromiseSTM var result

fulfillPromiseSTM :: MonadSTMc NoRetry '[PromiseAlreadyCompleted] m => Promise a -> a -> m ()
fulfillPromiseSTM var result = do
  success <- tryFulfillPromiseSTM var result
  unless success $ throwC PromiseAlreadyCompleted


tryFulfillPromise :: MonadIO m => Promise a -> a -> m Bool
tryFulfillPromise var result = atomically $ tryFulfillPromiseSTM var result

tryFulfillPromiseSTM :: MonadSTMc NoRetry '[] m => Promise a -> a -> m Bool
tryFulfillPromiseSTM (Promise var) result = tryPutTMVar var result



-- * Utility functions

afix :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m a) -> m a
afix = afixExtra . fmap (fmap dup)

afix_ :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m a) -> m ()
afix_ = void . afix

afixExtra :: (MonadIO m, MonadCatch m) => (FutureEx '[SomeException] a -> m (r, a)) -> m r
afixExtra action = do
  var <- newPromise
  catchAll
    do
      (result, fixResult) <- action (toFutureEx var)
      fulfillPromise var (Right fixResult)
      pure result
    \ex -> do
      fulfillPromise var (Left (toEx ex))
      throwM ex


-- ** Awaiting multiple awaitables


-- | Completes as soon as either awaitable completes.
awaitEither :: MonadAwait m => Future ra -> Future rb -> m (Either ra rb)
awaitEither (Future x) (Future y) = unsafeAwaitSTMc (eitherSTM x y)

-- | Helper for `awaitEither`
eitherSTM :: STMc Retry '[] a -> STMc Retry '[] b -> STMc Retry '[] (Either a b)
eitherSTM x y = fmap Left x `orElseC` fmap Right y


-- Completes as soon as any awaitable in the list is completed and then returns the left-most completed result
-- (or exception).
awaitAny :: MonadAwait m => [Future r] -> m r
awaitAny xs = unsafeAwaitSTMc $ anySTM $ awaitSTM <$> xs

-- | Helper for `awaitAny`
anySTM :: [STMc Retry '[] a] -> STMc Retry '[] a
anySTM [] = retry
anySTM (x:xs) = x `orElseC` anySTM xs


-- | Like `awaitAny` with two awaitables.
awaitAny2 :: MonadAwait m => Future r -> Future r -> m r
awaitAny2 x y = awaitAny [toFuture x, toFuture y]


-- TODO export; use for awaitEither and awaitAny
cacheFuture :: forall a m. MonadSTMc NoRetry '[] m => Future a -> m (Future a)
cacheFuture f = do
  cache <- newEmptyTMVar
  pure (unsafeAwaitSTMc (queryCache cache))
  where
    queryCache :: TMVar a -> STMc Retry '[] a
    queryCache cache = do
      tryReadTMVar cache >>= \case
        Just result -> pure result
        Nothing -> do
          result <- awaitSTM f
          putTMVar cache result
          pure result
