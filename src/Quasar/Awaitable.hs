module Quasar.Awaitable (
  -- * Awaitable
  IsAwaitable(..),
  MonadQuerySTM(..),
  awaitIO,
  peekAwaitable,
  Awaitable,
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
  cacheAwaitableDefaultImplementation,
) where

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
awaitIO awaitable = liftIO $ either throwIO pure =<< runQueryT (atomically . (maybe retry pure =<<)) (runAwaitable awaitable)

peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable awaitable = liftIO $ runMaybeT $ runQueryT (MaybeT . atomically) (runAwaitable awaitable)


data Awaitable r = forall a. IsAwaitable r a => Awaitable a

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = runAwaitable x
  cacheAwaitable (Awaitable x) = cacheAwaitable x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn (Awaitable x) = toAwaitable $ FnAwaitable $ fn <<$>> runAwaitable x

instance Applicative Awaitable where
  pure value = toAwaitable $ FnAwaitable $ pure (Right value)
  liftA2 fn (Awaitable fx) (Awaitable fy) = toAwaitable $ FnAwaitable $ liftA2 (liftA2 fn) (runAwaitable fx) (runAwaitable fy)

instance Monad Awaitable where
  (Awaitable fx) >>= fn = toAwaitable $ FnAwaitable $ do
    runAwaitable fx >>= \case
      Left ex -> pure $ Left ex
      Right x -> runAwaitable (fn x)

instance Semigroup r => Semigroup (Awaitable r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Awaitable r) where
  mempty = pure mempty


newtype FnAwaitable r = FnAwaitable (forall m. (MonadQuerySTM m) => m (Either SomeException r))

instance IsAwaitable r (FnAwaitable r) where
  runAwaitable (FnAwaitable x) = x
  cacheAwaitable = cacheAwaitableDefaultImplementation


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

-- | Create an awaitable from a `STM` transaction.
--
-- Use `retry` to signal that the awaitable is not yet completed and `throwM`/`throwSTM` to set the awaitable to failed.
simpleAwaitable :: STM a -> Awaitable a
simpleAwaitable query = toAwaitable $ FnAwaitable $ querySTM do
  (Just . Right <$> query) `orElse` pure Nothing
    `catchAll`
      \ex -> pure (Just (Left ex))

mapAwaitable :: IsAwaitable i a => (Either SomeException i -> Either SomeException r) -> a -> Awaitable r
mapAwaitable fn awaitable = toAwaitable $ FnAwaitable $  fn <$> runAwaitable awaitable


class Monad m => MonadQuerySTM m where
  querySTM :: (forall a. STM (Maybe a) -> m a)

instance Monad m => MonadQuerySTM (ReaderT (QueryFn m) m) where
  querySTM query = do
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
      go = querySTM stepCacheTransaction >>= \case
        AwaitableCompleted result -> pure result
        -- Cached operation is not yet completed
        _ -> go

      stepCacheTransaction :: STM (Maybe (AwaitableStepM (Either SomeException r)))
      stepCacheTransaction = do
        readTVar tvar >>= \case
          -- Cache was already completed
          result@(AwaitableCompleted _) -> pure $ Just result
          AwaitableStep query fn -> do
            -- Run the next "querySTM" query requested by the cached operation
            fn <<$>> query >>= \case
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
  | forall b. AwaitableStep (STM (Maybe b)) (b -> AwaitableStepM a)

instance Functor AwaitableStepM where
  fmap fn (AwaitableCompleted x) = AwaitableCompleted (fn x)
  fmap fn (AwaitableStep query next) = AwaitableStep query (fmap fn <$> next)

instance Applicative AwaitableStepM where
  pure = AwaitableCompleted
  liftA2 fn fx fy = fx >>= \x -> fn x <$> fy

instance Monad AwaitableStepM where
  (AwaitableCompleted x) >>= fn = fn x
  (AwaitableStep query next) >>= fn = AwaitableStep query (next >=> fn)

instance MonadQuerySTM AwaitableStepM where
  querySTM query = AwaitableStep query AwaitableCompleted


-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  runAwaitable (AsyncVar var) = querySTM $ tryReadTMVar var
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
awaitEither x y = toAwaitable $ FnAwaitable $ groupLefts <$> stepBoth (runAwaitable x) (runAwaitable y)
  where
    stepBoth :: MonadQuerySTM m => AwaitableStepM ra -> AwaitableStepM rb -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ = pure $ Left resultX
    stepBoth _ (AwaitableCompleted resultY) = pure $ Right resultY
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) = do
      querySTM (peekEitherSTM transactionX transactionY) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY
        Right resultY -> stepBoth stepX (nextY resultY)


awaitAny :: IsAwaitable r a => NonEmpty a -> Awaitable r
awaitAny xs = toAwaitable $ FnAwaitable $ stepAll Empty Empty $ runAwaitable <$> fromList (toList xs)
  where
    stepAll
      :: MonadQuerySTM m
      => Seq (STM (Maybe (Seq (AwaitableStepM r))))
      -> Seq (AwaitableStepM r)
      -> Seq (AwaitableStepM r)
      -> m r
    stepAll _ _ (AwaitableCompleted result :<| _) = pure result
    stepAll acc prevSteps (step@(AwaitableStep transaction next) :<| steps) =
      stepAll
        do acc |> ((\result -> (prevSteps |> next result) <> steps) <<$>> transaction)
        do prevSteps |> step
        steps
    stepAll acc ps Empty = do
      newAwaitableSteps <- querySTM $ maybe impossibleCodePathM peekAnySTM $ nonEmpty (toList acc)
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
