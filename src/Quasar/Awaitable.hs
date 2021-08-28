module Quasar.Awaitable (
  -- * Awaitable
  IsAwaitable(..),
  Awaitable,
  awaitIO,
  tryAwaitIO,
  peekAwaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  awaitSTM,
  unsafeAwaitSTM,

  -- * Awaitable helpers

  awaitSuccessOrFailure,

  -- ** Awaiting multiple awaitables
  awaitEither,
  awaitAny,
  awaitAny2,

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

  -- * Implementation helpers
  MonadQuerySTM(querySTM),
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


class IsAwaitable r a | a -> r where
  runAwaitable :: (MonadQuerySTM m) => a -> m r
  runAwaitable self = runAwaitable (toAwaitable self)

  cacheAwaitable :: MonadIO m => a -> m (Awaitable r)
  cacheAwaitable self = cacheAwaitable (toAwaitable self)

  toAwaitable :: a -> Awaitable r
  toAwaitable = Awaitable

  {-# MINIMAL toAwaitable | (runAwaitable, cacheAwaitable) #-}


awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO awaitable = liftIO $ runQueryT atomically (runAwaitable awaitable)

tryAwaitIO :: (IsAwaitable r a, MonadIO m) => a -> m (Either SomeException r)
tryAwaitIO awaitable = liftIO $ try $ awaitIO awaitable

peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable awaitable = liftIO $ runMaybeT $ try $ runQueryT queryFn (runAwaitable awaitable)
  where
    queryFn :: STM a -> MaybeT IO a
    queryFn transaction = MaybeT $ atomically $ (Just <$> transaction) `orElse` pure Nothing


data Awaitable r = forall a. IsAwaitable r a => Awaitable a

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = runAwaitable x
  cacheAwaitable (Awaitable x) = cacheAwaitable x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn (Awaitable x) = fnAwaitable $ fn <$> runAwaitable x

instance Applicative Awaitable where
  pure value = fnAwaitable $ pure value
  liftA2 fn (Awaitable fx) (Awaitable fy) = fnAwaitable $ liftA2 fn (runAwaitable fx) (runAwaitable fy)

instance Monad Awaitable where
  (Awaitable fx) >>= fn = fnAwaitable $ runAwaitable fx >>= runAwaitable . fn

instance Semigroup r => Semigroup (Awaitable r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Awaitable r) where
  mempty = pure mempty

instance MonadThrow Awaitable where
  throwM = failedAwaitable . toException

instance MonadCatch Awaitable where
  catch awaitable handler = fnAwaitable do
    runAwaitable awaitable `catch` \ex -> runAwaitable (handler ex)

instance MonadFail Awaitable where
  fail = throwM . userError


instance Alternative Awaitable where
  x <|> y = x `catchAll` const y
  empty = failedAwaitable $ toException $ userError "empty"

instance MonadPlus Awaitable



newtype FnAwaitable r = FnAwaitable (forall m. (MonadQuerySTM m) => m r)

instance IsAwaitable r (FnAwaitable r) where
  runAwaitable (FnAwaitable x) = x
  cacheAwaitable = cacheAwaitableDefaultImplementation

fnAwaitable :: (forall m. (MonadQuerySTM m) => m r) -> Awaitable r
fnAwaitable fn = toAwaitable $ FnAwaitable fn


newtype CompletedAwaitable r = CompletedAwaitable (Either SomeException r)

instance IsAwaitable r (CompletedAwaitable r) where
  runAwaitable (CompletedAwaitable x) = either throwM pure x
  cacheAwaitable = pure . toAwaitable


completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable result = toAwaitable $ CompletedAwaitable result

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
awaitSTM :: MonadIO m => STM a -> m (Awaitable a)
awaitSTM = cacheAwaitable . unsafeAwaitSTM

-- | Create an awaitable from an `STM` transaction. The STM transaction must always return the same result and should
-- not have visible side effects.
--
-- Use `retry` to signal that the awaitable is not yet completed and `throwM`/`throwSTM` to set the awaitable to failed.
unsafeAwaitSTM :: STM a -> Awaitable a
unsafeAwaitSTM query = fnAwaitable $ querySTM query


class MonadCatch m => MonadQuerySTM m where
  -- | Run an `STM` transaction. Use `retry` to signal that no value is available (yet).
  querySTM :: (forall a. STM a -> m a)


instance MonadCatch m => MonadQuerySTM (ReaderT (QueryFn m) m) where
  querySTM query = do
    QueryFn querySTMFn <- ask
    lift $ querySTMFn query

newtype QueryFn m = QueryFn (forall a. STM a -> m a)

runQueryT :: forall m a. (forall b. STM b -> m b) -> ReaderT (QueryFn m) m a -> m a
runQueryT queryFn action = runReaderT action (QueryFn queryFn)


newtype CachedAwaitable r = CachedAwaitable (TVar (AwaitableStepM r))

cacheAwaitableDefaultImplementation :: (IsAwaitable r a, MonadIO m) => a -> m (Awaitable r)
cacheAwaitableDefaultImplementation awaitable = toAwaitable . CachedAwaitable <$> liftIO (newTVarIO (runAwaitable awaitable))

instance IsAwaitable r (CachedAwaitable r) where
  runAwaitable :: forall m. (MonadQuerySTM m) => CachedAwaitable r -> m r
  runAwaitable (CachedAwaitable tvar) = go
    where
      go :: m r
      go = querySTM stepCacheTransaction >>= \case
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
  fmap fn (AwaitableFailed ex) = AwaitableFailed ex
  fmap fn (AwaitableStep query next) = AwaitableStep query (fmap fn <$> next)

instance Applicative AwaitableStepM where
  pure = AwaitableCompleted
  liftA2 fn fx fy = fx >>= \x -> fn x <$> fy

instance Monad AwaitableStepM where
  (AwaitableCompleted x) >>= fn = fn x
  (AwaitableFailed ex) >>= fn = AwaitableFailed ex
  (AwaitableStep query next) >>= fn = AwaitableStep query (next >=> fn)

instance MonadQuerySTM AwaitableStepM where
  querySTM query = AwaitableStep query (either AwaitableFailed AwaitableCompleted)

instance MonadThrow AwaitableStepM where
  throwM = AwaitableFailed . toException

instance MonadCatch AwaitableStepM where
  catch result@(AwaitableCompleted _) _ = result
  catch result@(AwaitableFailed ex) handler = maybe result handler $ fromException ex
  catch (AwaitableStep query next) handler = AwaitableStep query (\x -> next x `catch` handler)


-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  runAwaitable (AsyncVar var) = querySTM $ either throwM pure =<< readTMVar var
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

-- | Create an awaitable that is completed successfully when the input awaitable is successful or failed.
awaitSuccessOrFailure :: IsAwaitable r a => a -> Awaitable ()
awaitSuccessOrFailure = fireAndForget . toAwaitable
  where
    fireAndForget :: MonadCatch m => m r -> m ()
    fireAndForget x = void x `catchAll` const (pure ())

-- ** Awaiting multiple awaitables

awaitEither :: (IsAwaitable ra a, IsAwaitable rb b) => a -> b -> Awaitable (Either ra rb)
awaitEither x y = fnAwaitable $ stepBoth (runAwaitable x) (runAwaitable y)
  where
    stepBoth :: MonadQuerySTM m => AwaitableStepM ra -> AwaitableStepM rb -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ = pure $ Left resultX
    stepBoth (AwaitableFailed ex) _ = throwM ex
    stepBoth _ (AwaitableCompleted resultY) = pure $ Right resultY
    stepBoth _ (AwaitableFailed ex) = throwM ex
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) = do
      querySTM (eitherSTM (try transactionX) (try transactionY)) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY
        Right resultY -> stepBoth stepX (nextY resultY)


awaitAny :: IsAwaitable r a => NonEmpty a -> Awaitable r
awaitAny xs = fnAwaitable $ stepAll Empty Empty $ runAwaitable <$> fromList (toList xs)
  where
    stepAll
      :: MonadQuerySTM m
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
      newAwaitableSteps <- querySTM $ maybe impossibleCodePathM anySTM $ nonEmpty (toList acc)
      stepAll Empty Empty newAwaitableSteps


awaitAny2 :: IsAwaitable r a => a -> a -> Awaitable r
awaitAny2 x y = awaitAny (x :| [y])


eitherSTM :: STM a -> STM b -> STM (Either a b)
eitherSTM x y = fmap Left x `orElse` fmap Right y

anySTM :: NonEmpty (STM a) -> STM a
anySTM (x :| xs) = x `orElse` maybe retry anySTM (nonEmpty xs)
