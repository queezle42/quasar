module Quasar.Async (
  -- * Async/await
  MonadAsync(..),
  async,
  async_,
  asyncWithUnmask,
  asyncWithUnmask_,
  runUnlimitedAsync,

  -- ** Async context
  IsAsyncContext(..),
  AsyncContext,
  unlimitedAsyncContext,

  -- * Unmanaged forking
  forkTask,
  forkTask_,
  forkTaskWithUnmask,
  forkTaskWithUnmask_,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude
import Quasar.ResourceManager



class IsAsyncContext a where
  asyncOnContextWithUnmask :: MonadResourceManager m => a -> (forall f. MonadAsync f => (forall b. f b -> f b) -> f r) -> m (Awaitable r)
  asyncOnContextWithUnmask self = asyncOnContextWithUnmask (toAsyncContext self)

  toAsyncContext :: a -> AsyncContext
  toAsyncContext = AsyncContext

  {-# MINIMAL toAsyncContext | asyncOnContextWithUnmask #-}

data AsyncContext = forall a. IsAsyncContext a => AsyncContext a

instance IsAsyncContext AsyncContext where
  asyncOnContextWithUnmask (AsyncContext ctx) = asyncOnContextWithUnmask ctx

data UnlimitedAsyncContext = UnlimitedAsyncContext

unlimitedAsyncContext :: AsyncContext
unlimitedAsyncContext = toAsyncContext UnlimitedAsyncContext


instance IsAsyncContext UnlimitedAsyncContext where
  asyncOnContextWithUnmask UnlimitedAsyncContext action = do
    resourceManager <- askResourceManager
    let asyncContext = unlimitedAsyncContext
    toAwaitable <$> registerNewResource do
      forkTaskWithUnmask (\unmask -> runReaderT (runReaderT (action (liftUnmask unmask)) asyncContext) resourceManager)
    where
      liftUnmask :: (forall b. IO b -> IO b) -> ReaderT AsyncContext (ReaderT ResourceManager IO) a -> ReaderT AsyncContext (ReaderT ResourceManager IO) a
      liftUnmask unmask innerAction = do
        resourceManager <- askResourceManager
        asyncContext <- askAsyncContext
        liftIO $ unmask $ runReaderT (runReaderT innerAction asyncContext) resourceManager


class MonadResourceManager m => MonadAsync m where
  askAsyncContext :: m AsyncContext

  localAsyncContext :: IsAsyncContext a => a -> m r -> m r


instance MonadResourceManager m => MonadAsync (ReaderT AsyncContext m) where
  askAsyncContext = ask
  localAsyncContext = local . const . toAsyncContext

instance {-# OVERLAPPABLE #-} MonadAsync m => MonadAsync (ReaderT r m) where
  askAsyncContext = lift askAsyncContext
  localAsyncContext asyncContext action = do
    x <- ask
    lift $ localAsyncContext asyncContext $ runReaderT action x


-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions unmasked.
async :: MonadAsync m => (forall f. MonadAsync f => f a) -> m (Awaitable a)
async action = asyncWithUnmask \unmask -> unmask action

-- | TODO: Documentation
--
-- The action will be run with asynchronous exceptions masked and will be passed an action that can be used to unmask.
asyncWithUnmask :: MonadAsync m => (forall f. MonadAsync f => (forall a. f a -> f a) -> f r) -> m (Awaitable r)
asyncWithUnmask action = do
  asyncContext <- askAsyncContext
  asyncOnContextWithUnmask asyncContext action

async_ :: MonadAsync m => (forall f. MonadAsync f => f ()) -> m ()
async_ action = void $ async action

asyncWithUnmask_ :: MonadAsync m => (forall f. MonadAsync f => (forall a. f a -> f a) -> f ()) -> m ()
asyncWithUnmask_ action = void $ asyncWithUnmask action



-- | Run a computation in `MonadAsync` where `async` is implemented without any thread limits (i.e. every `async` will
-- fork a new (RTS) thread).
runUnlimitedAsync :: ReaderT AsyncContext m a -> m a
runUnlimitedAsync action = do
  runReaderT action unlimitedAsyncContext



forkTask :: MonadIO m => IO a -> m (Task a)
forkTask action = forkTaskWithUnmask \unmask -> unmask action

forkTask_ :: MonadIO m => IO () -> m Disposable
forkTask_ action = toDisposable <$> forkTask action

forkTaskWithUnmask :: MonadIO m => ((forall b. IO b -> IO b) -> IO a) -> m (Task a)
forkTaskWithUnmask action = do
  liftIO $ mask_ do
    resultVar <- newAsyncVar
    threadIdVar <- newEmptyTMVarIO

    disposable <- newDisposable $ disposeTask threadIdVar resultVar

    onException
      do
        atomically . putTMVar threadIdVar . Just =<<
          forkIOWithUnmask \unmask -> do
            result <- try $ catch
              do action unmask
              \CancelTask -> throwIO TaskDisposed

            putAsyncVarEither_ resultVar result

            -- Thread has completed work, "disarm" the disposable and fire it
            void $ atomically $ swapTMVar threadIdVar Nothing
            disposeAndAwait disposable

      do atomically $ putTMVar threadIdVar Nothing

    pure $ Task disposable (toAwaitable resultVar)
  where
    disposeTask :: TMVar (Maybe ThreadId) -> AsyncVar r -> IO (Awaitable ())
    disposeTask threadIdVar resultVar = mask_ do
      -- Blocks until the thread is forked
      atomically (swapTMVar threadIdVar Nothing) >>= \case
        -- Thread completed or initialization failed
        Nothing -> pure ()
        Just threadId -> throwTo threadId CancelTask

      -- Wait for task completion or failure. Tasks must not ignore `CancelTask` or this will hang.
      pure $ void (toAwaitable resultVar) `catchAll` const (pure ())

forkTaskWithUnmask_ :: MonadIO m => ((forall b. IO b -> IO b) -> IO ()) -> m Disposable
forkTaskWithUnmask_ action = toDisposable <$> forkTaskWithUnmask action
