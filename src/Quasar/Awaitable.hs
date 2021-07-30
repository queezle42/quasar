module Quasar.Awaitable (
  -- * Awaitable
  IsAwaitable(..),
  awaitIO,
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
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
import Data.Bifunctor (bimap)
import Quasar.Prelude


class IsAwaitable r a | a -> r where
  peekSTM :: a -> STM (Maybe (Either (Awaitable r) (Either SomeException r)))
  peekSTM = peekSTM . toAwaitable

  toAwaitable :: a -> Awaitable r
  toAwaitable x = Awaitable (peekSTM x)

  {-# MINIMAL toAwaitable | peekSTM #-}


awaitIO :: (IsAwaitable r a, MonadIO m) => a -> m r
awaitIO input = liftIO $ either throwIO pure =<< go (toAwaitable input)
  where
    go :: Awaitable r -> IO (Either SomeException r)
    go x = do
      stepResult <- atomically $ maybe retry pure =<< peekSTM x
      either go pure stepResult


newtype Awaitable r = Awaitable (STM (Maybe (Either (Awaitable r) (Either SomeException r))))

instance IsAwaitable r (Awaitable r) where
  peekSTM (Awaitable x) = x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn = Awaitable . fmap (fmap (bimap (fmap fn) (fmap fn))) . peekSTM


completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable = Awaitable . pure . Just . Right

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left


peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable input = liftIO $ go (toAwaitable input)
  where
    go :: Awaitable r -> IO (Maybe (Either SomeException r))
    go x = atomically (peekSTM x) >>= \case
      Nothing -> pure Nothing
      Just (Right result) -> pure $ Just result
      Just (Left step) -> go step


-- | Cache an `Awaitable`
--awaitableFromSTM :: STM (Maybe (Either SomeException r)) -> IO (Awaitable r)
--awaitableFromSTM fn = do
--  cache <- newTVarIO (Left fn)
--  pure . Awaitable $
--    readTVar cache >>= \case
--      Left generatorFn -> do
--        value <- generatorFn
--        writeTVar cache (Right value)
--        pure value
--      Right value -> pure value



-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  peekSTM (AsyncVar var) = fmap Right <$> tryReadTMVar var


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

-- TODO
--awaitEither :: (IsAwaitable ra a , IsAwaitable rb b, MonadIO m) => a -> b -> m (Awaitable (Either ra rb))
--awaitEither x y = liftIO $ awaitableFromSTM $ peekEitherSTM x y
--
--peekEitherSTM :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> STM (Maybe (Either SomeException (Either ra rb)))
--peekEitherSTM x y =
--  peekSTM x >>= \case
--    Just (Left ex) -> pure (Just (Left ex))
--    Just (Right r) -> pure (Just (Right (Left r)))
--    Nothing -> peekSTM y >>= \case
--      Just (Left ex) -> pure (Just (Left ex))
--      Just (Right r) -> pure (Just (Right (Right r)))
--      Nothing -> pure Nothing
