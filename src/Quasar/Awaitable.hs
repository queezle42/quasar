module Quasar.Awaitable (
  -- * MonadAwaitable
  MonadAwait(..),
  awaitResult,
  peekAwaitable,

  -- * Awaitable
  IsAwaitable(..),
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  awaitableFromSTM,
  unsafeAwaitSTM,

  -- * Awaitable helpers

  awaitSuccessOrFailure,

  -- ** Awaiting multiple awaitables
  awaitAny,
  awaitAny2,
  awaitEither,

  -- * AsyncVar
  AsyncVar,

  -- ** Manage `AsyncVar`s in IO
  newAsyncVar,
  putAsyncVarEither,
  putAsyncVar,
  putAsyncVar_,
  failAsyncVar,
  failAsyncVar_,
  putAsyncVarEither_,

  -- ** Manage `AsyncVar`s in STM
  newAsyncVarSTM,
  putAsyncVarEitherSTM,
  putAsyncVarSTM,
  putAsyncVarSTM_,
  failAsyncVarSTM,
  failAsyncVarSTM_,
  putAsyncVarEitherSTM_,
  readAsyncVarSTM,

  -- * Implementation helpers
  cacheAwaitableDefaultImplementation,
) where

import Control.Applicative (empty)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Data.Foldable (toList)
import Data.Sequence
import Quasar.Prelude


class (MonadCatch m, MonadFail m, MonadPlus m) => MonadAwait m where
  -- | Wait until an awaitable is completed and then return it's value (or throw an exception).
  await :: IsAwaitable r a => a -> m r

  -- | Await an `STM` transaction. The STM transaction must always return the same result and should not have visible
  -- side effects.
  --
  -- Use `retry` to signal that the awaitable is not yet completed and use `throwM`/`throwSTM` to signal a failed
  -- awaitable.
  unsafeAwaitSTM :: STM a -> m a

instance MonadAwait IO where
  await awaitable = liftIO $ runQueryT atomically (runAwaitable awaitable)
  unsafeAwaitSTM = atomically

instance MonadAwait m => MonadAwait (ReaderT a m) where
  await = lift . await
  unsafeAwaitSTM = lift . unsafeAwaitSTM


awaitResult :: (IsAwaitable r a, MonadAwait m) => m a -> m r
awaitResult = (await =<<)


-- | Returns the result (in a `Just`) when the awaitable is completed, throws an `Exception` when the awaitable is
-- failed and returns `Nothing` otherwise.
peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe r)
peekAwaitable awaitable = liftIO $ runMaybeT $ runQueryT queryFn (runAwaitable awaitable)
  where
    queryFn :: STM a -> MaybeT IO a
    queryFn transaction = MaybeT $ atomically $ (Just <$> transaction) `orElse` pure Nothing



class IsAwaitable r a | a -> r where
  -- | Run the awaitable. You probably want to use `await` instead, `runAwaitable` is exposed to implement an instance
  -- of `IsAwaitable`.
  --
  -- The implementation of `async` calls `runAwaitable` in most monads, so the implementation of `runAwaitable` must
  -- not call `async` without deconstructing first.
  runAwaitable :: (MonadAwait m) => a -> m r
  runAwaitable self = runAwaitable (toAwaitable self)

  cacheAwaitable :: MonadIO m => a -> m (Awaitable r)
  cacheAwaitable self = cacheAwaitable (toAwaitable self)

  toAwaitable :: a -> Awaitable r
  toAwaitable = Awaitable

  {-# MINIMAL toAwaitable | (runAwaitable, cacheAwaitable) #-}


data Awaitable r = forall a. IsAwaitable r a => Awaitable a

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = runAwaitable x
  cacheAwaitable (Awaitable x) = cacheAwaitable x
  toAwaitable = id

instance MonadAwait Awaitable where
  await = toAwaitable
  unsafeAwaitSTM transaction = mkMonadicAwaitable $ unsafeAwaitSTM transaction

instance Functor Awaitable where
  fmap fn (Awaitable x) = mkMonadicAwaitable $ fn <$> runAwaitable x

instance Applicative Awaitable where
  pure = successfulAwaitable
  liftA2 fn (Awaitable fx) (Awaitable fy) = mkMonadicAwaitable $ liftA2 fn (runAwaitable fx) (runAwaitable fy)

instance Monad Awaitable where
  (Awaitable fx) >>= fn = mkMonadicAwaitable $ runAwaitable fx >>= runAwaitable . fn

instance Semigroup r => Semigroup (Awaitable r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Awaitable r) where
  mempty = pure mempty

instance MonadThrow Awaitable where
  throwM = failedAwaitable . toException

instance MonadCatch Awaitable where
  catch awaitable handler = mkMonadicAwaitable do
    runAwaitable awaitable `catch` \ex -> runAwaitable (handler ex)

instance MonadFail Awaitable where
  fail = throwM . userError


instance Alternative Awaitable where
  x <|> y = x `catchAll` const y
  empty = failedAwaitable $ toException $ userError "empty"

instance MonadPlus Awaitable



newtype MonadicAwaitable r = MonadicAwaitable (forall m. MonadAwait m => m r)

instance IsAwaitable r (MonadicAwaitable r) where
  runAwaitable (MonadicAwaitable x) = x
  cacheAwaitable = cacheAwaitableDefaultImplementation

mkMonadicAwaitable :: MonadAwait m => (forall f. (MonadAwait f) => f r) -> m r
mkMonadicAwaitable fn = await $ MonadicAwaitable fn


newtype CompletedAwaitable r = CompletedAwaitable (Either SomeException r)

instance IsAwaitable r (CompletedAwaitable r) where
  runAwaitable (CompletedAwaitable x) = either throwM pure x
  cacheAwaitable = pure . toAwaitable


completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable result = toAwaitable $ CompletedAwaitable result

-- | Alias for `pure`.
successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left

-- | Create an awaitable from an `STM` transaction.
--
-- The first value or exception returned from the STM transaction will be cached and returned. The STM transacton
-- should not have visible side effects.
--
-- Use `retry` to signal that the awaitable is not yet completed and `throwM`/`throwSTM` to set the awaitable to failed.
awaitableFromSTM :: forall m a. MonadIO m => STM a -> m (Awaitable a)
awaitableFromSTM transaction = cacheAwaitable (unsafeAwaitSTM transaction :: Awaitable a)


instance {-# OVERLAPS #-} (MonadCatch m, MonadFail m, MonadPlus m) => MonadAwait (ReaderT (QueryFn m) m) where
  await = runAwaitable
  unsafeAwaitSTM transaction = do
    QueryFn querySTMFn <- ask
    lift $ querySTMFn transaction

newtype QueryFn m = QueryFn (forall a. STM a -> m a)

runQueryT :: forall m a. (forall b. STM b -> m b) -> ReaderT (QueryFn m) m a -> m a
runQueryT queryFn action = runReaderT action (QueryFn queryFn)


newtype CachedAwaitable r = CachedAwaitable (TVar (AwaitableStepM r))

cacheAwaitableDefaultImplementation :: (IsAwaitable r a, MonadIO m) => a -> m (Awaitable r)
cacheAwaitableDefaultImplementation awaitable = toAwaitable . CachedAwaitable <$> liftIO (newTVarIO (runAwaitable awaitable))

instance IsAwaitable r (CachedAwaitable r) where
  runAwaitable :: forall m. MonadAwait m => CachedAwaitable r -> m r
  runAwaitable (CachedAwaitable tvar) = go
    where
      go :: m r
      go = unsafeAwaitSTM stepCacheTransaction >>= \case
        AwaitableCompleted result -> pure result
        AwaitableFailed ex -> throwM ex
        -- Cached operation is not yet completed
        _ -> go

      stepCacheTransaction :: STM (AwaitableStepM r)
      stepCacheTransaction = do
        readTVar tvar >>= \case
          -- Cache needs to be stepped
          AwaitableStep query fn -> do
            -- Run the next "querySTM" query requested by the cached operation
            -- The query might `retry`, which is ok here
            nextStep <- fn <$> try query
            -- In case of an incomplete query the caller (/ the monad `m`) can decide what to do (e.g. retry for
            -- `awaitIO`, abort for `peekAwaitable`)
            -- Query was successful. Update cache and exit query
            writeTVar tvar nextStep
            pure nextStep
          -- Cache was already completed
          result -> pure result

  cacheAwaitable = pure . toAwaitable

data AwaitableStepM a
  = AwaitableCompleted a
  | AwaitableFailed SomeException
  | forall b. AwaitableStep (STM b) (Either SomeException b -> AwaitableStepM a)

instance Functor AwaitableStepM where
  fmap fn (AwaitableCompleted x) = AwaitableCompleted (fn x)
  fmap _ (AwaitableFailed ex) = AwaitableFailed ex
  fmap fn (AwaitableStep query next) = AwaitableStep query (fmap fn <$> next)

instance Applicative AwaitableStepM where
  pure = AwaitableCompleted
  liftA2 fn fx fy = fx >>= \x -> fn x <$> fy

instance Monad AwaitableStepM where
  (AwaitableCompleted x) >>= fn = fn x
  (AwaitableFailed ex) >>= _ = AwaitableFailed ex
  (AwaitableStep query next) >>= fn = AwaitableStep query (next >=> fn)

instance MonadAwait AwaitableStepM where
  await = runAwaitable
  unsafeAwaitSTM query = AwaitableStep query (either AwaitableFailed AwaitableCompleted)

instance MonadThrow AwaitableStepM where
  throwM = AwaitableFailed . toException

instance MonadCatch AwaitableStepM where
  catch result@(AwaitableCompleted _) _ = result
  catch result@(AwaitableFailed ex) handler = maybe result handler $ fromException ex
  catch (AwaitableStep query next) handler = AwaitableStep query (\x -> next x `catch` handler)

instance MonadFail AwaitableStepM where
  fail = throwM . userError

instance Alternative AwaitableStepM where
  x <|> y = x `catchAll` const y
  empty = throwM $ toException $ userError "empty"

instance MonadPlus AwaitableStepM where


-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  runAwaitable (AsyncVar var) = unsafeAwaitSTM $ either throwM pure =<< readTMVar var
  -- An AsyncVar is a primitive awaitable, so caching is not necessary
  cacheAwaitable = pure . toAwaitable


newAsyncVarSTM :: STM (AsyncVar r)
newAsyncVarSTM = AsyncVar <$> newEmptyTMVar

newAsyncVar :: MonadIO m => m (AsyncVar r)
newAsyncVar = liftIO $ AsyncVar <$> newEmptyTMVarIO


putAsyncVarEither :: forall a m. MonadIO m => AsyncVar a -> Either SomeException a -> m Bool
putAsyncVarEither var = liftIO . atomically . putAsyncVarEitherSTM var

putAsyncVarEitherSTM :: AsyncVar a -> Either SomeException a -> STM Bool
putAsyncVarEitherSTM (AsyncVar var) = tryPutTMVar var


-- | Get the value of an `AsyncVar` in `STM`. Will retry until the AsyncVar is fulfilled.
readAsyncVarSTM :: AsyncVar a -> STM a
readAsyncVarSTM (AsyncVar var) = either throwM pure =<< readTMVar var


putAsyncVar :: MonadIO m => AsyncVar a -> a -> m Bool
putAsyncVar var = putAsyncVarEither var . Right

putAsyncVarSTM :: AsyncVar a -> a -> STM Bool
putAsyncVarSTM var = putAsyncVarEitherSTM var . Right

putAsyncVar_ :: MonadIO m => AsyncVar a -> a -> m ()
putAsyncVar_ var = void . putAsyncVar var

putAsyncVarSTM_ :: AsyncVar a -> a -> STM ()
putAsyncVarSTM_ var = void . putAsyncVarSTM var

failAsyncVar :: (Exception e, MonadIO m) => AsyncVar a -> e -> m Bool
failAsyncVar var = putAsyncVarEither var . Left . toException

failAsyncVarSTM :: Exception e => AsyncVar a -> e -> STM Bool
failAsyncVarSTM var = putAsyncVarEitherSTM var . Left . toException

failAsyncVar_ :: (Exception e, MonadIO m) => AsyncVar a -> e -> m ()
failAsyncVar_ var = void . failAsyncVar var

failAsyncVarSTM_ :: Exception e => AsyncVar a -> e -> STM ()
failAsyncVarSTM_ var = void . failAsyncVarSTM var

putAsyncVarEither_ :: MonadIO m => AsyncVar a -> Either SomeException a -> m ()
putAsyncVarEither_ var = void . putAsyncVarEither var

putAsyncVarEitherSTM_ :: AsyncVar a -> Either SomeException a -> STM ()
putAsyncVarEitherSTM_ var = void . putAsyncVarEitherSTM var



-- * Utility functions

-- | Await success or failure of another awaitable, then return `()`.
awaitSuccessOrFailure :: (IsAwaitable r a, MonadAwait m) => a -> m ()
awaitSuccessOrFailure = await . fireAndForget . toAwaitable
  where
    fireAndForget :: MonadCatch m => m r -> m ()
    fireAndForget x = void x `catchAll` const (pure ())

-- ** Awaiting multiple awaitables


-- | Completes as soon as either awaitable completes.
awaitEither :: (IsAwaitable ra a, IsAwaitable rb b, MonadAwait m) => a -> b -> m (Either ra rb)
awaitEither x y = mkMonadicAwaitable $ stepBoth (runAwaitable x) (runAwaitable y)
  where
    stepBoth :: MonadAwait m => AwaitableStepM ra -> AwaitableStepM rb -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ = pure $ Left resultX
    stepBoth (AwaitableFailed ex) _ = throwM ex
    stepBoth _ (AwaitableCompleted resultY) = pure $ Right resultY
    stepBoth _ (AwaitableFailed ex) = throwM ex
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) = do
      unsafeAwaitSTM (eitherSTM (try transactionX) (try transactionY)) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY
        Right resultY -> stepBoth stepX (nextY resultY)

-- | Helper for `awaitEither`
eitherSTM :: STM a -> STM b -> STM (Either a b)
eitherSTM x y = fmap Left x `orElse` fmap Right y


-- Completes as soon as any awaitable in the list is completed and then returns the left-most completed result
-- (or exception).
awaitAny :: (IsAwaitable r a, MonadAwait m) => NonEmpty a -> m r
awaitAny xs = mkMonadicAwaitable $ stepAll Empty Empty $ runAwaitable <$> fromList (toList xs)
  where
    stepAll
      :: MonadAwait m
      => Seq (STM (Seq (AwaitableStepM r)))
      -> Seq (AwaitableStepM r)
      -> Seq (AwaitableStepM r)
      -> m r
    stepAll _ _ (AwaitableCompleted result :<| _) = pure result
    stepAll _ _ (AwaitableFailed ex :<| _) = throwM ex
    stepAll acc prevSteps (step@(AwaitableStep transaction next) :<| steps) =
      stepAll
        do acc |> ((\result -> (prevSteps |> next result) <> steps) <$> try transaction)
        do prevSteps |> step
        steps
    stepAll acc _ Empty = do
      newAwaitableSteps <- unsafeAwaitSTM $ maybe impossibleCodePathM anySTM $ nonEmpty (toList acc)
      stepAll Empty Empty newAwaitableSteps

-- | Helper for `awaitAny`
anySTM :: NonEmpty (STM a) -> STM a
anySTM (x :| xs) = x `orElse` maybe retry anySTM (nonEmpty xs)


-- | Like `awaitAny` with two awaitables.
awaitAny2 :: (IsAwaitable r a, MonadAwait m) => a -> a -> m r
awaitAny2 x y = awaitAny (x :| [y])
