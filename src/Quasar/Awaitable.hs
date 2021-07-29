module Quasar.Awaitable (
  -- * Awaitable
  IsAwaitable(..),
  awaitIO,
  awaitSTM,
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  awaitableFromSTM,
  peekAwaitable,

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
import Quasar.Prelude


class IsAwaitable r a | a -> r where
  peekSTM :: a -> STM (Maybe (Either SomeException r))
  peekSTM = peekSTM . toAwaitable

  toAwaitable :: a -> Awaitable r
  toAwaitable x = Awaitable (peekSTM x)

  {-# MINIMAL toAwaitable | peekSTM #-}


-- | Wait until the promise is settled and return the result.
awaitSTM :: IsAwaitable r a => a -> STM (Either SomeException r)
awaitSTM = peekSTM >=> maybe retry pure

awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO action = liftIO $ either throwIO pure =<< atomically (awaitSTM action)


newtype Awaitable r = Awaitable (STM (Maybe (Either SomeException r)))

instance IsAwaitable r (Awaitable r) where
  peekSTM (Awaitable x) = x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn = Awaitable . fmap (fmap (fmap fn)) . peekSTM


completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable = Awaitable . pure . Just

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left


peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable = liftIO . atomically . peekSTM


awaitableFromSTM :: STM (Maybe (Either SomeException r)) -> IO (Awaitable r)
awaitableFromSTM fn = do
  cache <- newTVarIO (Left fn)
  pure . Awaitable $
    readTVar cache >>= \case
      Left generatorFn -> do
        value <- generatorFn
        writeTVar cache (Right value)
        pure value
      Right value -> pure value



-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  peekSTM (AsyncVar var) = tryReadTMVar var


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
