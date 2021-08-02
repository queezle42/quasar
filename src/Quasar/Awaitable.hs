module Quasar.Awaitable (
  -- * Awaitable
  IsAwaitable(..),
  awaitIO,
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  peekAwaitable,
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
import Control.Monad.Fix (mfix)
import Control.Monad.Reader
import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import Data.Bifunctor (bimap)
import Quasar.Prelude



class IsAwaitable r a | a -> r where
  runAwaitable :: (Monad m) => a -> (forall b. STM (Maybe b) -> m b) -> m (Either SomeException r)
  runAwaitable self = runAwaitable (toAwaitable self)

  toAwaitable :: a -> Awaitable r
  toAwaitable x = Awaitable $ runAwaitable x

  {-# MINIMAL toAwaitable | runAwaitable #-}


awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO awaitable = liftIO $ either throwIO pure =<< runAwaitable awaitable (atomically . (maybe retry pure =<<))

peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable awaitable = liftIO . runMaybeT $ runAwaitable awaitable (MaybeT . atomically)


newtype Awaitable r = Awaitable (forall m. (Monad m) => (forall b. STM (Maybe b) -> m b) -> m (Either SomeException r))

instance IsAwaitable r (Awaitable r) where
  runAwaitable (Awaitable x) = x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn (Awaitable x) = Awaitable $ \querySTM -> fn <<$>> x querySTM

instance Applicative Awaitable where
  pure value = Awaitable $ \_ -> pure (Right value)
  liftA2 fn (Awaitable fx) (Awaitable fy) = Awaitable $ \querySTM -> liftA2 (liftA2 fn) (fx querySTM) (fy querySTM)

instance Monad Awaitable where
  (Awaitable fx) >>= fn = Awaitable $ \querySTM -> do
    fx querySTM >>= \case
      Left ex -> pure $ Left ex
      Right x -> runAwaitable (fn x) querySTM



completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable result = Awaitable $ \_ -> pure result

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left

simpleAwaitable :: STM (Maybe (Either SomeException a)) -> Awaitable a
simpleAwaitable peekTransaction = Awaitable ($ peekTransaction)


class Monad m => MonadQuerySTM m where
  querySTM :: (forall a. STM (Maybe a) -> m a)

instance Monad m => MonadQuerySTM (ReaderT (QuerySTMFunction m) m) where
  querySTM query = do
    QuerySTMFunction querySTMFn <- ask
    lift $ querySTMFn query

data QuerySTMFunction m = QuerySTMFunction (forall b. STM (Maybe b) -> m b)


newtype CachedAwaitable r = CachedAwaitable (TVar (AwaitableStepM (Either SomeException r)))

instance IsAwaitable r (CachedAwaitable r) where
  runAwaitable :: forall m. (Monad m) => CachedAwaitable r -> (forall b. STM (Maybe b) -> m b) -> m (Either SomeException r)
  runAwaitable (CachedAwaitable tvar) querySTM = go
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
          AwaitableStep transaction fn -> do
            -- Run the next "querySTM" transaction requested by the cached operation
            fn <<$>> transaction >>= \case
              -- In case of an incomplete transaction the caller (/ the monad `m`) can decide what to do (e.g. retry for `awaitIO`, abort for `peekAwaitable`)
              Nothing -> pure Nothing
              -- Query was successful. Update cache and exit transaction
              Just nextStep -> do
                writeTVar tvar nextStep
                pure $ Just nextStep

cacheAwaitable :: Awaitable a -> IO (CachedAwaitable a)
cacheAwaitable awaitable = CachedAwaitable <$> newTVarIO (peekM awaitable peekStep)

data AwaitableStepM a
  = AwaitableCompleted a
  | forall b. AwaitableStep (STM (Maybe b)) (b -> AwaitableStepM a)

instance Functor AwaitableStepM where
  fmap fn (AwaitableCompleted x) = AwaitableCompleted (fn x)
  fmap fn (AwaitableStep transaction next) = AwaitableStep transaction (fmap fn <$> next)

instance Applicative AwaitableStepM where
  pure = AwaitableCompleted
  liftA2 fn fx fy = fx >>= \x -> fn x <$> fy

instance Monad AwaitableStepM where
  (AwaitableCompleted x) >>= fn = fn x
  (AwaitableStep transaction next) >>= fn = AwaitableStep transaction (next >=> fn)

instance MonadQuerySTM AwaitableStepM where
  querySTM transaction = AwaitableStep transaction AwaitableCompleted


peekStep :: STM (Maybe a) -> AwaitableStepM a
peekStep transaction = AwaitableStep transaction AwaitableCompleted


-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  runAwaitable (AsyncVar var) = ($ tryReadTMVar var)


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
  let startX = runAwaitable x peekStep
  let startY = runAwaitable y peekStep
  pure $ Awaitable $ \querySTM -> groupLefts <$> stepBoth startX startY querySTM
  where
    stepBoth :: Monad m => AwaitableStepM ra -> AwaitableStepM rb -> (forall c. STM (Maybe c) -> m c) -> m (Either ra rb)
    stepBoth (AwaitableCompleted resultX) _ _ = pure $ Left resultX
    stepBoth _ (AwaitableCompleted resultY) _ = pure $ Right resultY
    stepBoth stepX@(AwaitableStep transactionX nextX) stepY@(AwaitableStep transactionY nextY) querySTM = do
      querySTM (peekEitherSTM transactionX transactionY) >>= \case
        Left resultX -> stepBoth (nextX resultX) stepY querySTM
        Right resultY -> stepBoth stepX (nextY resultY) querySTM


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
