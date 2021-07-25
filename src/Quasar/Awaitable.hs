module Quasar.Awaitable (
  IsAwaitable(..),
  awaitSTM,
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  awaitableFromSTM,
  peekAwaitable,
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

