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
  simpleAwaitable,
  mapAwaitable,

  -- * Awaiting multiple awaitables
  awaitEither,
  awaitAny,
  awaitAny2,

  -- * AsyncVar
  AsyncVar,
  newAsyncVar,
  newAsyncVarSTM,
  putAsyncVarEither,
  putAsyncVarEitherSTM,
  putAsyncVar,
  putAsyncVar_,
  failAsyncVar,
  failAsyncVar_,
  putAsyncVarEither_,
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
  runAwaitable :: (MonadQuerySTM m) => a -> m (Either SomeException r)
  runAwaitable self = runAwaitable (toAwaitable self)

  cacheAwaitable :: MonadIO m => a -> m (Awaitable r)
  cacheAwaitable self = cacheAwaitable (toAwaitable self)

  toAwaitable :: a -> Awaitable r
  toAwaitable = Awaitable

  {-# MINIMAL toAwaitable | (runAwaitable, cacheAwaitable) #-}


awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO awaitable = liftIO $ either throwIO pure =<<
  runQueryT (atomically . (maybe retry pure =<<)) (runAwaitable awaitable)

tryAwaitIO :: (IsAwaitable r a, MonadIO m) => a -> m (Either SomeException r)
tryAwaitIO awaitable = liftIO $ fmap join $ try $
  runQueryT (atomically . (maybe retry pure =<<)) (runAwaitable awaitable)

peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable awaitable = liftIO $ runMaybeT $ runQueryT (MaybeT . atomically) (runAwaitable awaitable)


data Awaitable r = forall a. IsAwaitable r a => Awaitable a

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = runAwaitable x
  cacheAwaitable (Awaitable x) = cacheAwaitable x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn (Awaitable x) = fnAwaitable $ fn <<$>> runAwaitable x

instance Applicative Awaitable where
  pure value = fnAwaitable $ pure (Right value)
  liftA2 fn (Awaitable fx) (Awaitable fy) = fnAwaitable $ liftA2 (liftA2 fn) (runAwaitable fx) (runAwaitable fy)

instance Monad Awaitable where
  (Awaitable fx) >>= fn = fnAwaitable $ do
    runAwaitable fx >>= \case
      Left ex -> pure $ Left ex
      Right x -> runAwaitable (fn x)

instance Semigroup r => Semigroup (Awaitable r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Awaitable r) where
  mempty = pure mempty

instance MonadThrow Awaitable where
  throwM = failedAwaitable . toException

instance MonadCatch Awaitable where
  catch awaitable handler = fnAwaitable do
    runAwaitable awaitable >>= \case
      l@(Left ex) -> maybe (pure l) (runAwaitable . handler) $ fromException ex
      Right value -> pure $ Right value

instance MonadFail Awaitable where
  fail = throwM . userError


instance Alternative Awaitable where
  x <|> y = x `catchAll` const y
  empty = failedAwaitable $ toException $ userError "empty"

instance MonadPlus Awaitable



newtype FnAwaitable r = FnAwaitable (forall m. (MonadQuerySTM m) => m (Either SomeException r))

instance IsAwaitable r (FnAwaitable r) where
  runAwaitable (FnAwaitable x) = x
  cacheAwaitable = cacheAwaitableDefaultImplementation

fnAwaitable :: (forall m. (MonadQuerySTM m) => m (Either SomeException r)) -> Awaitable r
fnAwaitable fn = toAwaitable $ FnAwaitable fn


newtype CompletedAwaitable r = CompletedAwaitable (Either SomeException r)

instance IsAwaitable r (CompletedAwaitable r) where
  runAwaitable (CompletedAwaitable x) = pure x
  cacheAwaitable = pure . toAwaitable


completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable result = toAwaitable $ CompletedAwaitable result

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left

-- | Create an awaitable from an `STM` transaction.
--
-- Use `retry` to signal that the awaitable is not yet completed and `throwM`/`throwSTM` to set the awaitable to failed.
simpleAwaitable :: STM a -> Awaitable a
simpleAwaitable query = fnAwaitable $ querySTM do
  (Right <$> query)
    `catchAll`
      \ex -> pure (Left ex)

mapAwaitable :: IsAwaitable i a => (Either SomeException i -> Either SomeException r) -> a -> Awaitable r
mapAwaitable fn awaitable = fnAwaitable $  fn <$> runAwaitable awaitable


class MonadThrow m => MonadQuerySTM m where
  -- | Run an `STM` transaction. `retry` can be used.
  querySTM :: (forall a. STM a -> m a)
  querySTM transaction = unsafeQuerySTM $ (Just <$> transaction) `orElse` pure Nothing

  -- | Run an "STM` transaction. `retry` MUST NOT be used.
  unsafeQuerySTM :: (forall a. STM (Maybe a) -> m a)
  unsafeQuerySTM transaction = querySTM $ maybe retry pure =<< transaction

  {-# MINIMAL querySTM | unsafeQuerySTM #-}

instance MonadThrow m => MonadQuerySTM (ReaderT (QueryFn m) m) where
  unsafeQuerySTM query = do
    QueryFn querySTMFn <- ask
    lift $ querySTMFn query

newtype QueryFn m = QueryFn (forall a. STM (Maybe a) -> m a)

runQueryT :: forall m a. (forall b. STM (Maybe b) -> m b) -> ReaderT (QueryFn m) m a -> m a
runQueryT queryFn action = runReaderT action (QueryFn queryFn)


newtype CachedAwaitable r = CachedAwaitable (TVar (AwaitableStepM (Either SomeException r)))

cacheAwaitableDefaultImplementation :: (IsAwaitable r a, MonadIO m) => a -> m (Awaitable r)
cacheAwaitableDefaultImplementation awaitable = toAwaitable . CachedAwaitable <$> liftIO (newTVarIO (runAwaitable awaitable))

instance IsAwaitable r (CachedAwaitable r) where
  runAwaitable :: forall m. (MonadQuerySTM m) => CachedAwaitable r -> m (Either SomeException r)
  runAwaitable (CachedAwaitable tvar) = go
    where
      go :: m (Either SomeException r)
      go = unsafeQuerySTM stepCacheTransaction >>= \case
        AwaitableCompleted result -> pure result
        AwaitableFailed ex -> pure (Left ex)
        -- Cached operation is not yet completed
        _ -> go

      stepCacheTransaction :: STM (Maybe (AwaitableStepM (Either SomeException r)))
      stepCacheTransaction = do
        readTVar tvar >>= \case
          -- Cache was already completed
          result@(AwaitableCompleted _) -> pure $ Just result
          result@(AwaitableFailed _) -> pure $ Just result
          AwaitableStep query fn -> do
            -- Run the next "querySTM" query requested by the cached operation
            queryResult <- (fn <<$>> query) `catchAll` (pure . Just . AwaitableFailed)
            case queryResult of
              -- In case of an incomplete query the caller (/ the monad `m`) can decide what to do (e.g. retry for
              -- `awaitIO`, abort for `peekAwaitable`)
              Nothing -> pure Nothing
              -- Query was successful. Update cache and exit query
              Just nextStep -> do
                writeTVar tvar nextStep
                pure $ Just nextStep

  cacheAwaitable = pure . toAwaitable

data AwaitableStepM a
  = AwaitableCompleted a
  | AwaitableFailed SomeException
  | forall b. AwaitableStep (STM (Maybe b)) (b -> AwaitableStepM a)

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
  unsafeQuerySTM query = AwaitableStep query AwaitableCompleted

instance MonadThrow AwaitableStepM where
  throwM = AwaitableFailed . toException


-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  runAwaitable (AsyncVar var) = unsafeQuerySTM $ tryReadTMVar var
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

putAsyncVar_ :: MonadIO m => AsyncVar a -> a -> m ()
putAsyncVar_ var = void . putAsyncVar var

failAsyncVar :: MonadIO m => AsyncVar a -> SomeException -> m Bool
failAsyncVar var = putAsyncVarEither var . Left

failAsyncVar_ :: MonadIO m => AsyncVar a -> SomeException -> m ()
failAsyncVar_ var = void . failAsyncVar var

putAsyncVarEither_ :: MonadIO m => AsyncVar a -> Either SomeException a -> m ()
putAsyncVarEither_ var = void . putAsyncVarEither var

putAsyncVarEitherSTM_ :: AsyncVar a -> Either SomeException a -> STM ()
putAsyncVarEitherSTM_ var = void . putAsyncVarEitherSTM var



-- * Awaiting multiple asyncs

awaitEither :: (IsAwaitable ra a, IsAwaitable rb b) => a -> b -> Awaitable (Either ra rb)
awaitEither x y = fnAwaitable $ groupLefts <$> stepBoth (runAwaitable x) (runAwaitable y)
  where
    stepBoth :: MonadQuerySTM m => AwaitableStepM ra -> AwaitableStepM rb -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ = pure $ Left resultX
    stepBoth (AwaitableFailed ex) _ = throwM ex
    stepBoth _ (AwaitableCompleted resultY) = pure $ Right resultY
    stepBoth _ (AwaitableFailed ex) = throwM ex
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) = do
      unsafeQuerySTM (peekEitherSTM transactionX transactionY) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY
        Right resultY -> stepBoth stepX (nextY resultY)


awaitAny :: IsAwaitable r a => NonEmpty a -> Awaitable r
awaitAny xs = fnAwaitable $ stepAll Empty Empty $ runAwaitable <$> fromList (toList xs)
  where
    stepAll
      :: MonadQuerySTM m
      => Seq (STM (Maybe (Seq (AwaitableStepM r))))
      -> Seq (AwaitableStepM r)
      -> Seq (AwaitableStepM r)
      -> m r
    stepAll _ _ (AwaitableCompleted result :<| _) = pure result
    stepAll _ _ (AwaitableFailed ex :<| _) = throwM ex
    stepAll acc prevSteps (step@(AwaitableStep transaction next) :<| steps) =
      stepAll
        do acc |> ((\result -> (prevSteps |> next result) <> steps) <<$>> transaction)
        do prevSteps |> step
        steps
    stepAll acc _ Empty = do
      newAwaitableSteps <- unsafeQuerySTM $ maybe impossibleCodePathM peekAnySTM $ nonEmpty (toList acc)
      stepAll Empty Empty newAwaitableSteps


awaitAny2 :: IsAwaitable r a => a -> a -> Awaitable r
awaitAny2 x y = awaitAny (x :| [y])


groupLefts :: Either (Either ex a) (Either ex b) -> Either ex (Either a b)
groupLefts (Left x) = Left <$> x
groupLefts (Right y) = Right <$> y

peekEitherSTM :: STM (Maybe a) -> STM (Maybe b) -> STM (Maybe (Either a b))
peekEitherSTM x y =
  x >>= \case
    Just r -> pure (Just (Left r))
    Nothing -> y >>= \case
      Just r -> pure (Just (Right r))
      Nothing -> pure Nothing

peekAnySTM :: NonEmpty (STM (Maybe a)) -> STM (Maybe a)
peekAnySTM (x :| xs) = x >>= \case
  r@(Just _) -> pure r
  Nothing -> maybe (pure Nothing) peekAnySTM (nonEmpty xs)
