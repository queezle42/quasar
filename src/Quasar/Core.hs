module Quasar.Core (
  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  awaitResult,
) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, myThreadId)
import Control.Concurrent.STM
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.HashSet
import Data.Sequence
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
runAsyncIO = withDefaultPool

runOnPool :: Pool -> AsyncIO r -> AsyncIO r
runOnPool pool work = await =<< (liftIO . atomically $ queueWork pool work)

data AsyncCall r = forall a. AsyncCall (Awaitable a) (Either SomeException a -> AsyncIO r)
asyncCall :: Awaitable a -> (Either SomeException a -> AsyncIO r) -> AsyncCall r
asyncCall = AsyncCall

data StepResult r
  = StepResultCompleted r
  | StepResultAwaitable (Awaitable r)
  | StepResultAsyncCall (AsyncCall r)

stepAsyncIO :: Pool -> AsyncIO r -> IO (StepResult r)
stepAsyncIO pool = go
  where
    --packResult :: Either SomeException (StepResult r) -> Either (AsyncCall r) (Awaitable r)
    --packResult (Left ex) = Right (failedAwaitable ex)
    --packResult (Right (StepResultCompleted x)) = Right (successfulAwaitable x)
    --packResult (Right (StepResultAwaitable x)) = Right x
    --packResult (Right (StepResultAsyncCall x)) = Left x

    go :: AsyncIO r -> IO (StepResult r)
    go (AsyncIOCompleted x) = StepResultCompleted <$> either throwIO pure x
    go (AsyncIOIO x) = StepResultCompleted <$> x
    go (AsyncIOAwait x) =
      atomically (peekSTM x) >>= \case
        Nothing -> pure $ StepResultAwaitable x
        Just (Left ex) -> throwIO ex
        Just (Right r) -> pure $ StepResultCompleted r
    go (AsyncIOBind x fn) = do
      go x >>= \case
        StepResultCompleted r -> go (fn r)
        StepResultAwaitable awaitable -> pure $ StepResultAsyncCall (asyncCall awaitable foobar)
        (StepResultAsyncCall call) -> continueAfterCall call foobar
      where
        foobar = either throwM fn
    go (AsyncIOCatch x handler) = do
      try (go x) >>= \case
        Left ex -> go (handler ex)
        Right (StepResultCompleted r) -> pure $ StepResultCompleted r
        Right (StepResultAwaitable awaitable) -> pure $ StepResultAsyncCall (asyncCall awaitable foobar)
        Right (StepResultAsyncCall c) -> continueAfterCall c foobar
      where
        foobar = either (handleSomeException handler) pure
    go AsyncIOAskPool = pure $ StepResultCompleted pool

    continueAfterCall :: AsyncCall a -> (Either SomeException a -> AsyncIO r) -> IO (StepResult r)
    continueAfterCall call fn = do
      -- Tail call optimization is not possible when having to wait for the result of a call, so the call is queued as a new work item.
      awaitable <- atomically $ queueBlockedWork pool call
      pure $ StepResultAsyncCall $ asyncCall awaitable fn

    handleSomeException :: forall e a m. (Exception e, MonadThrow m) => (e -> m a) -> SomeException -> m a
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
  configuration :: PoolConfiguraiton,
  queue :: TVar (Seq AsyncWorkItem),
  threads :: TVar (HashSet ThreadId)
}

newtype AsyncTask r = AsyncTask (Awaitable r)
instance IsAwaitable r (AsyncTask r) where
  toAwaitable (AsyncTask awaitable) = awaitable

data AsyncWorkItem = forall r. AsyncWorkItem (AsyncCall r) (Awaitable r -> IO ())

newtype AsyncWorkResult r = AsyncWorkResult (TMVar (Awaitable r))
instance IsAwaitable r (AsyncWorkResult r) where
  peekSTM (AsyncWorkResult var) = peekSTM =<< readTMVar var

completeWork :: AsyncWorkResult r -> Awaitable r -> IO ()
completeWork (AsyncWorkResult var) = atomically . putTMVar var


data PoolConfiguraiton = PoolConfiguraiton

defaultPoolConfiguration :: PoolConfiguraiton
defaultPoolConfiguration = PoolConfiguraiton

withPool :: PoolConfiguraiton -> AsyncIO r -> IO r
withPool configuration work = mask $ \unmask -> do
  pool <- newPool configuration
  task <- atomically $ newTask pool work

  result <- awaitAndThrowTo task unmask `finally` pure () -- TODO dispose pool

  either throwIO pure result

  where
    awaitAndThrowTo :: AsyncTask r -> (forall a. IO a -> IO a) -> IO (Either SomeException r)
    -- TODO handle asynchronous exceptions (stop pool)
    awaitAndThrowTo task unmask = unmask (atomically (awaitSTM task)) `catchAll` (\ex -> undefined >> awaitAndThrowTo task unmask)

withDefaultPool :: AsyncIO a -> IO a
withDefaultPool = withPool defaultPoolConfiguration

newPool :: PoolConfiguraiton -> IO Pool
newPool configuration = do
  queue <- newTVarIO mempty
  threads <- newTVarIO mempty
  let pool = Pool {
    configuration,
    queue,
    threads
  }
  void $ forkIO (managePool pool)
  pure pool
  where
    managePool :: Pool -> IO ()
    managePool pool = forever $ do
      worker <- atomically $ takeWorkItem (toWorker pool) pool
      void $ forkIO worker

    workerSetup :: Pool -> IO () -> (forall a. IO a -> IO a) -> IO ()
    workerSetup pool worker unmask = do
      unmask worker

newTask :: Pool -> AsyncIO r -> STM (AsyncTask r)
newTask pool work = do
  awaitable <- queueWork pool work
  pure $ AsyncTask awaitable


queueWorkItem :: Pool -> AsyncWorkItem -> STM ()
queueWorkItem pool item = do
  modifyTVar' (queue pool) (|> item)

queueWork :: Pool -> AsyncIO r -> STM (Awaitable r)
queueWork pool work = queueBlockedWork pool $ asyncCall (successfulAwaitable ()) (const work)

queueBlockedWork :: Pool -> AsyncCall r -> STM (Awaitable r)
queueBlockedWork pool call = do
  resultVar <- AsyncWorkResult <$> newEmptyTMVar
  queueWorkItem pool $ AsyncWorkItem call (completeWork resultVar)
  pure $ toAwaitable resultVar

toWorker :: Pool -> AsyncWorkItem -> STM (Maybe (IO ()))
toWorker pool (AsyncWorkItem (AsyncCall inputAwaitable work) putResult) = worker <<$>> peekSTM inputAwaitable
  where
    worker input = do
      threadId <- myThreadId
      atomically $ modifyTVar (threads pool) $ insert threadId

      stepAsyncIO pool (work input) >>= \case
        StepResultCompleted r -> putResult (successfulAwaitable r)
        StepResultAwaitable x -> putResult x
        -- This is an async tail call. Tail call optimization is performed by reusing `putResult`.
        StepResultAsyncCall call -> atomically $ queueWorkItem pool (AsyncWorkItem call putResult)

      atomically . modifyTVar (threads pool) . delete =<< myThreadId


takeWorkItem :: forall a. (AsyncWorkItem -> STM (Maybe a)) -> Pool -> STM a
takeWorkItem fn pool = do
  items <- readTVar (queue pool)
  (item, remaining) <- nextWorkItem Empty items
  writeTVar (queue pool) remaining
  pure item
  where
    nextWorkItem :: Seq AsyncWorkItem -> Seq AsyncWorkItem -> STM (a, Seq AsyncWorkItem)
    nextWorkItem remaining (item :<| seq) = do
      fn item >>= \case
        Just work -> pure (work, remaining <> seq)
        Nothing -> nextWorkItem (remaining |> item) seq
    nextWorkItem _ _ = retry




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
