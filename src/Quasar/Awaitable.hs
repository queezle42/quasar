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
  cacheAwaitable,
  awaitEither,

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
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Quasar.Prelude


class IsAwaitable r a | a -> r where
  runAwaitable :: (MonadQuerySTM m) => a -> m (Either SomeException r)
  runAwaitable self = runAwaitable (toAwaitable self)

  toAwaitable :: a -> Awaitable r
  toAwaitable x = Awaitable $ runAwaitable x

  {-# MINIMAL toAwaitable | runAwaitable #-}


awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO awaitable = liftIO $ either throwIO pure =<< runQueryT (atomically . (maybe retry pure =<<)) (runAwaitable awaitable)

peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable awaitable = liftIO $ runMaybeT $ runQueryT (MaybeT . atomically) (runAwaitable awaitable)


newtype Awaitable r = Awaitable (forall m. (MonadQuerySTM m) => m (Either SomeException r))

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn (Awaitable x) = Awaitable $ fn <<$>> x

instance Applicative Awaitable where
  pure value = Awaitable $ pure (Right value)
  liftA2 fn (Awaitable fx) (Awaitable fy) = Awaitable $ liftA2 (liftA2 fn) fx fy

instance Monad Awaitable where
  (Awaitable fx) >>= fn = Awaitable $ do
    fx >>= \case
      Left ex -> pure $ Left ex
      Right x -> runAwaitable (fn x)

instance Semigroup r => Semigroup (Awaitable r) where
  x <> y = liftA2 (<>) x y

instance Monoid r => Monoid (Awaitable r) where
  mempty = pure mempty



completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable result = Awaitable $ pure result

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left

simpleAwaitable :: STM (Maybe (Either SomeException a)) -> Awaitable a
simpleAwaitable query = Awaitable (querySTM query)

mapAwaitable :: IsAwaitable i a => (Either SomeException i -> Either SomeException r) -> a -> Awaitable r
mapAwaitable fn awaitable = Awaitable $ fn <$> runAwaitable awaitable


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

cacheAwaitable :: Awaitable a -> IO (CachedAwaitable a)
cacheAwaitable awaitable = CachedAwaitable <$> newTVarIO (runAwaitable awaitable)

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
              -- In case of an incomplete query the caller (/ the monad `m`) can decide what to do (e.g. retry for `awaitIO`, abort for `peekAwaitable`)
              Nothing -> pure Nothing
              -- Query was successful. Update cache and exit query
              Just nextStep -> do
                writeTVar tvar nextStep
                pure $ Just nextStep

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

awaitEither :: (IsAwaitable ra a , IsAwaitable rb b, MonadIO m) => a -> b -> m (Awaitable (Either ra rb))
awaitEither x y = liftIO $ do
  let startX = runAwaitable x
  let startY = runAwaitable y
  pure $ Awaitable $ groupLefts <$> stepBoth startX startY
  where
    stepBoth :: MonadQuerySTM m => AwaitableStepM ra -> AwaitableStepM rb -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ = pure $ Left resultX
    stepBoth _ (AwaitableCompleted resultY) = pure $ Right resultY
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) = do
      querySTM (peekEitherSTM transactionX transactionY) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY
        Right resultY -> stepBoth stepX (nextY resultY)


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
