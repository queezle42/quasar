module Quasar.Core (
  -- * AsyncManager
  AsyncManager,
  AsyncManagerConfiguraiton(..),
  MonadAsync(..),
  withAsyncManager,
  withDefaultAsyncManager,
  withUnlimitedAsyncManager,
  newAsyncManager,
  defaultAsyncManagerConfiguration,
  unlimitedAsyncManagerConfiguration,

  -- * Task
  Task,
  cancelTask,
  cancelTaskIO,
  toTask,
  completedTask,
  successfulTask,
  failedTask,

  -- * AsyncIO
  AsyncIO,
  async,
  await,
  awaitResult,

  -- * Disposable
  IsDisposable(..),
  Disposable,
  disposeIO,
  newDisposable,
  synchronousDisposable,
  noDisposable,

  -- ** ResourceManager
  ResourceManager,
  newResourceManager,
  disposeEventually,
  attachDisposable,
  attachDisposeAction,
  attachDisposeAction_,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet
import Quasar.Awaitable
import Quasar.Prelude



-- | A monad for actions that run on a thread bound to a `AsyncManager`.
newtype AsyncIO a = AsyncIO (ReaderT AsyncManager IO a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask)


-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: MonadAsync m => AsyncIO r -> m (Task r)
async action = asyncWithUnmask (\unmask -> unmask action)

-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
asyncWithUnmask :: MonadAsync m => ((forall a. AsyncIO a -> AsyncIO a) -> AsyncIO r) -> m (Task r)
-- TODO resource limits
asyncWithUnmask action = do
  asyncManager <- askAsyncManager
  resultVar <- newAsyncVar
  liftIO $ mask_ $ do
    void $ forkIOWithUnmask $ \unmask -> do
      result <- try $ runOnAsyncManager asyncManager (action (liftUnmask unmask))
      putAsyncVarEither_ resultVar result
    pure $ Task (toAwaitable resultVar)

liftUnmask :: (IO a -> IO a) -> AsyncIO a -> AsyncIO a
liftUnmask unmask action = do
  asyncManager <- askAsyncManager
  liftIO $ unmask $ runOnAsyncManager asyncManager action

await :: IsAwaitable r a => a -> AsyncIO r
-- TODO resource limits
await = liftIO . awaitIO


class MonadIO m => MonadAsync m where
  askAsyncManager :: m AsyncManager

instance MonadAsync AsyncIO where
  askAsyncManager = AsyncIO ask

instance MonadIO m => MonadAsync (ReaderT AsyncManager m) where
  askAsyncManager = ask


awaitResult :: IsAwaitable r a => AsyncIO a -> AsyncIO r
awaitResult = (await =<<)

data AsyncManager = AsyncManager {
  resourceManager :: ResourceManager,
  configuration :: AsyncManagerConfiguraiton,
  threads :: TVar (HashSet ThreadId)
}

instance IsDisposable AsyncManager where
  toDisposable = undefined

instance HasResourceManager AsyncManager where
  getResourceManager = resourceManager


-- | A task that is running asynchronously. It has a result and can fail.
-- The result (or exception) can be aquired by using the `IsAwaitable` class (e.g. by calling `await` or `awaitIO`).
-- It might be possible to cancel the task by using the `IsDisposable` class if the operation has not been completed.
-- If the result is no longer required the task should be cancelled, to avoid leaking memory.
newtype Task r = Task (Awaitable r)

instance IsAwaitable r (Task r) where
  toAwaitable (Task awaitable) = awaitable

instance IsDisposable (Task r) where
  toDisposable = undefined

instance Functor Task where
  fmap fn (Task x) = Task (fn <$> x)

instance Applicative Task where
  pure = Task . pure
  liftA2 fn (Task fx) (Task fy) = Task $ liftA2 fn fx fy

cancelTask :: Task r -> IO (Awaitable ())
cancelTask = dispose

cancelTaskIO :: Task r -> IO ()
cancelTaskIO = awaitIO <=< dispose

-- | Creates an `Task` from an `Awaitable`.
-- The resulting task only depends on an external resource, so disposing it has no effect.
toTask :: IsAwaitable r a => a -> Task r
toTask = Task . toAwaitable

completedTask :: Either SomeException r -> Task r
completedTask = toTask . completedAwaitable

-- | Alias for `pure`
successfulTask :: r -> Task r
successfulTask = pure

failedTask :: SomeException -> Task r
failedTask = toTask . failedAwaitable



data CancelTask = CancelTask
  deriving stock Show
instance Exception CancelTask where

data CancelledTask = CancelledTask
  deriving stock Show
instance Exception CancelledTask where


data AsyncManagerConfiguraiton = AsyncManagerConfiguraiton {
  maxThreads :: Maybe Int
}

defaultAsyncManagerConfiguration :: AsyncManagerConfiguraiton
defaultAsyncManagerConfiguration = AsyncManagerConfiguraiton {
  maxThreads = Just 1
}

unlimitedAsyncManagerConfiguration :: AsyncManagerConfiguraiton
unlimitedAsyncManagerConfiguration = AsyncManagerConfiguraiton {
  maxThreads = Nothing
}

withAsyncManager :: AsyncManagerConfiguraiton -> AsyncIO r -> IO r
withAsyncManager configuration = bracket (newAsyncManager configuration) disposeAsyncManager . flip runOnAsyncManager

runOnAsyncManager :: AsyncManager -> AsyncIO r -> IO r
runOnAsyncManager asyncManager (AsyncIO action) = runReaderT action asyncManager

withDefaultAsyncManager :: AsyncIO a -> IO a
withDefaultAsyncManager = withAsyncManager defaultAsyncManagerConfiguration

withUnlimitedAsyncManager :: AsyncIO a -> IO a
withUnlimitedAsyncManager = withAsyncManager unlimitedAsyncManagerConfiguration

newAsyncManager :: AsyncManagerConfiguraiton -> IO AsyncManager
newAsyncManager configuration = do
  threads <- newTVarIO mempty
  pure AsyncManager {
    configuration,
    threads
  }

disposeAsyncManager :: AsyncManager -> IO ()
-- TODO resource management
disposeAsyncManager = const (pure ())



-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource.
  dispose :: a -> IO (Awaitable ())
  dispose = dispose . toDisposable

  isDisposed :: a -> Awaitable ()
  isDisposed = isDisposed . toDisposable

  toDisposable :: a -> Disposable
  toDisposable = Disposable

  {-# MINIMAL toDisposable | (dispose, isDisposed) #-}

-- | Dispose a resource in the IO monad.
disposeIO :: IsDisposable a => a -> IO ()
disposeIO = awaitIO <=< dispose

instance IsDisposable a => IsDisposable (Maybe a) where
  toDisposable = maybe noDisposable toDisposable



data Disposable = forall a. IsDisposable a => Disposable a

instance IsDisposable Disposable where
  dispose (Disposable x) = dispose x
  toDisposable = id

instance Semigroup Disposable where
  x <> y = toDisposable $ CombinedDisposable x y

instance Monoid Disposable where
  mempty = toDisposable EmptyDisposable
  mconcat = toDisposable . ListDisposable

instance IsAwaitable () Disposable where
  toAwaitable = isDisposed


newtype FnDisposable = FnDisposable (TMVar (Either (IO (Awaitable ())) (Awaitable ())))

instance IsDisposable FnDisposable where
  dispose (FnDisposable var) =
    bracketOnError
      do atomically $ takeTMVar var
      do atomically . putTMVar var
      \case
        Left action -> do
          awaitable <- action
          atomically $ putTMVar var $ Right awaitable
          pure awaitable
        Right awaitable -> pure awaitable

  isDisposed = toAwaitable

instance IsAwaitable () FnDisposable where
  runAwaitable :: (MonadQuerySTM m) => FnDisposable -> m (Either SomeException ())
  runAwaitable (FnDisposable var) = do
    -- Query if dispose has started
    awaitable <- querySTM $ join . fmap rightToMaybe <$> tryReadTMVar var
    -- Query if dispose is completed
    runAwaitable awaitable



data CombinedDisposable = CombinedDisposable Disposable Disposable

instance IsDisposable CombinedDisposable where
  dispose (CombinedDisposable x y) = liftA2 (<>) (dispose x) (dispose y)
  isDisposed (CombinedDisposable x y) = liftA2 (<>) (isDisposed x) (isDisposed y)

newtype ListDisposable = ListDisposable [Disposable]

instance IsDisposable ListDisposable where
  dispose (ListDisposable disposables) = mconcat <$> traverse dispose disposables
  isDisposed (ListDisposable disposables) = traverse_ isDisposed disposables



data EmptyDisposable = EmptyDisposable

instance IsDisposable EmptyDisposable where
  dispose _ = pure $ pure ()
  isDisposed _ = successfulAwaitable ()



newDisposable :: MonadIO m => IO (Awaitable ()) -> m Disposable
newDisposable = liftIO . fmap (toDisposable . FnDisposable) . newTMVarIO . Left

synchronousDisposable :: IO () -> IO Disposable
synchronousDisposable = newDisposable . fmap pure . liftIO

noDisposable :: Disposable
noDisposable = mempty


data ResourceManager = ResourceManager

class HasResourceManager a where
  getResourceManager :: a -> ResourceManager

instance IsDisposable ResourceManager where
  toDisposable = undefined

newResourceManager :: IO ResourceManager
newResourceManager = pure ResourceManager

-- | Start disposing a resource but instead of waiting for the operation to complete, pass the responsibility to a `ResourceManager`.
--
-- The synchronous part of the `dispose`-Function will be run immediately but the resulting `Awaitable` will be passed to the resource manager.
disposeEventually :: (IsDisposable a, MonadIO m) => ResourceManager -> a -> m ()
disposeEventually _resourceManager disposable = liftIO $ do
  disposeCompleted <- dispose disposable
  peekAwaitable disposeCompleted >>= \case
    Just (Left ex) -> throwIO ex
    Just (Right ()) -> pure ()
    Nothing -> undefined -- TODO register on resourceManager

attachDisposable :: (IsDisposable a, MonadIO m) => ResourceManager -> a -> m ()
attachDisposable _resourceManager disposable = undefined

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m Disposable
attachDisposeAction resourceManager action = do
  disposable <- newDisposable action
  attachDisposable resourceManager disposable
  pure disposable

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m ()
attachDisposeAction_ resourceManager action = void $ attachDisposeAction resourceManager action
