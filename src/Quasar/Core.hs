module Quasar.Core (
  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  awaitResult,

  -- * Cancellation
  withCancellationToken,
) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.Maybe (isJust)
import Data.Void (absurd)
import Quasar.Awaitable
import Quasar.Prelude


-- * AsyncIO

data AsyncIO r
  = AsyncIOCompleted (Either SomeException r)
  | AsyncIOIO (IO r)
  | AsyncIOAwait (Awaitable r)
  | forall a. AsyncIOBind (AsyncIO a) (a -> AsyncIO r)
  | forall e. Exception e => AsyncIOCatch (AsyncIO r) (e -> AsyncIO r)
  | r ~ Pool => AsyncIOAskPool

instance Functor AsyncIO where
  fmap fn (AsyncIOCompleted x) = AsyncIOCompleted (fn <$> x)
  fmap fn (AsyncIOIO x) = AsyncIOIO (fn <$> x)
  fmap fn (AsyncIOAwait x) = AsyncIOAwait (fn <$> x)
  fmap fn (AsyncIOBind x y) = AsyncIOBind x (fn <<$>> y)
  fmap fn (AsyncIOCatch x y) = AsyncIOCatch (fn <$> x) (fn <<$>> y)
  fmap fn AsyncIOAskPool = AsyncIOBind AsyncIOAskPool (pure . fn)

instance Applicative AsyncIO where
  pure = AsyncIOCompleted . Right
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py

instance Monad AsyncIO where
  (>>=) :: forall a b. AsyncIO a -> (a -> AsyncIO b) -> AsyncIO b
  x >>= fn = AsyncIOBind x fn

instance MonadIO AsyncIO where
  liftIO = AsyncIOIO

instance MonadThrow AsyncIO where
  throwM = AsyncIOCompleted . Left . toException

instance MonadCatch AsyncIO where
  catch :: Exception e => AsyncIO a -> (e -> AsyncIO a) -> AsyncIO a
  catch = AsyncIOCatch


-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Awaitable r)
async (AsyncIOCompleted x) = pure $ completedAwaitable x
async (AsyncIOAwait x) = pure x
async x = do
  pool <- askPool
  liftIO . atomically $ queueWork pool x

askPool :: AsyncIO Pool
askPool = AsyncIOAskPool

await :: IsAwaitable r a => a -> AsyncIO r
await = AsyncIOAwait . toAwaitable

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO x = withDefaultPool $ \pool -> runAsyncIOWithPool pool x

runAsyncIOWithPool :: Pool -> AsyncIO r -> IO r
runAsyncIOWithPool pool x = do
  stepResult <- stepAsyncIO pool x
  case stepResult of
    Left awaitable -> either throwIO pure =<< atomically (awaitSTM awaitable)
    Right result -> pure result


stepAsyncIO :: Pool -> AsyncIO r -> IO (Either (Awaitable r) r)
stepAsyncIO pool = go
  where
    go :: AsyncIO r -> IO (Either (Awaitable r) r)
    go (AsyncIOCompleted x) = Right <$> either throwIO pure x
    go (AsyncIOIO x) = Right <$> x
    go (AsyncIOAwait x) = pure $ Left x
    go (AsyncIOBind x fn) = do
      go x >>= \case
        Left awaitable -> bindAwaitable awaitable (either throwM fn)
        Right r -> go (fn r)
    go (AsyncIOCatch x handler) = do
      try (go x) >>= \case
        Left ex -> go (handler ex)
        Right (Left awaitable) -> bindAwaitable awaitable (either (handleSomeException handler) pure)
        Right (Right r) -> pure $ Right r
    go AsyncIOAskPool = pure $ Right pool

    bindAwaitable :: Awaitable a -> (Either SomeException a -> AsyncIO r) -> IO (Either (Awaitable r) r)
    bindAwaitable input work = fmap Left . atomically $ queueBlockedWork pool input work

handleSomeException :: (Exception e, MonadThrow m) => (e -> m a) -> SomeException -> m a
handleSomeException handler ex = maybe (throwM ex) handler (fromException ex)

awaitResult :: AsyncIO (Awaitable r) -> AsyncIO r
awaitResult = (await =<<)

-- TODO rename
-- AsyncIOPool
-- AsyncPool
-- ThreadPool
-- AsyncIORuntime
-- AsyncIOContext
data Pool = Pool {
  queue :: TVar [AsyncQueueItem]
}

data AsyncQueueItem = forall a. AsyncQueueItem (Awaitable a) (Either SomeException a -> AsyncIO ())

withPool :: (Pool -> IO a) -> IO a
withPool = undefined

withDefaultPool :: (Pool -> IO a) -> IO a
withDefaultPool = (=<< atomically defaultPool)

defaultPool :: STM Pool
defaultPool = do
  queue <- newTVar []
  pure Pool {
    queue
  }

queueWork :: Pool -> AsyncIO r -> STM (Awaitable r)
queueWork pool work = queueBlockedWork pool (successfulAwaitable ()) (const work)

queueBlockedWork :: Pool -> Awaitable a -> (Either SomeException a -> AsyncIO r) -> STM (Awaitable r)
queueBlockedWork pool input work = do
  resultVar <- newAsyncVarSTM
  -- TODO masking state
  let actualWork = try . work >=> putAsyncVarEither_ resultVar
  undefined
  pure $ toAwaitable resultVar


-- * Awaiting multiple asyncs

awaitEither :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> AsyncIO (Either ra rb)
awaitEither x y = await =<< liftIO (awaitEitherPlumbing x y)

awaitEitherPlumbing :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> IO (Awaitable (Either ra rb))
awaitEitherPlumbing x y = awaitableFromSTM $ peekEitherSTM x y

peekEitherSTM :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> STM (Maybe (Either SomeException (Either ra rb)))
peekEitherSTM x y =
  peekSTM x >>= \case
    Just (Left ex) -> pure (Just (Left ex))
    Just (Right r) -> pure (Just (Right (Left r)))
    Nothing -> peekSTM y >>= \case
      Just (Left ex) -> pure (Just (Left ex))
      Just (Right r) -> pure (Just (Right (Right r)))
      Nothing -> pure Nothing


-- * Cancellation

newtype CancellationToken = CancellationToken (AsyncVar Void)

instance IsAwaitable Void CancellationToken where
  toAwaitable (CancellationToken var) = toAwaitable var

newCancellationToken :: IO CancellationToken
newCancellationToken = CancellationToken <$> newAsyncVar

cancel :: Exception e => CancellationToken -> e -> IO ()
cancel (CancellationToken var) = failAsyncVar_ var . toException

isCancellationRequested :: CancellationToken -> IO Bool
isCancellationRequested (CancellationToken var) = isJust <$> peekAwaitable var

cancellationState :: CancellationToken -> IO (Maybe SomeException)
cancellationState (CancellationToken var) = (either Just (const Nothing) =<<) <$> peekAwaitable var

throwIfCancellationRequested :: CancellationToken -> IO ()
throwIfCancellationRequested (CancellationToken var) =
  peekAwaitable var >>= \case
    Just (Left ex) -> throwIO ex
    _ -> pure ()

awaitUnlessCancellationRequested :: IsAwaitable a b => CancellationToken -> b -> AsyncIO a
awaitUnlessCancellationRequested cancellationToken = fmap (either absurd id) . awaitEither cancellationToken . toAwaitable


withCancellationToken :: (CancellationToken -> IO a) -> IO a
withCancellationToken action = do
  cancellationToken <- newCancellationToken
  resultMVar :: MVar (Either SomeException a) <- newEmptyMVar

  uninterruptibleMask $ \unmask -> do
    void $ forkIOWithUnmask $ \threadUnmask -> do
      putMVar resultMVar =<< try (threadUnmask (action cancellationToken))

    -- TODO test if it is better to run readMVar recursively or to keep it uninterruptible
    either throwIO pure =<< (unmask (readMVar resultMVar) `catchAll` (\ex -> cancel cancellationToken ex >> readMVar resultMVar))
