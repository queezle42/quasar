module Quasar.Core (
  -- * ResourceManager
  ResourceManager,
  ResourceManagerConfiguraiton(..),
  HasResourceManager(..),
  withResourceManager,
  withDefaultResourceManager,
  withUnlimitedResourceManager,
  newResourceManager,
  defaultResourceManagerConfiguration,
  unlimitedResourceManagerConfiguration,

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
  disposeEventually,
  boundDisposable,
  attachDisposeAction,
  attachDisposeAction_,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet
import Data.Sequence
import Quasar.Awaitable
import Quasar.Prelude



-- | A monad for actions that run on a thread bound to a `ResourceManager`.
newtype AsyncIO a = AsyncIO (ReaderT ResourceManager IO a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask)


-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: HasResourceManager m => AsyncIO r -> m (Task r)
async action = asyncWithUnmask (\unmask -> unmask action)

-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
asyncWithUnmask :: HasResourceManager m => ((forall a. AsyncIO a -> AsyncIO a) -> AsyncIO r) -> m (Task r)
-- TODO resource limits
asyncWithUnmask action = do
  resourceManager <- askResourceManager
  resultVar <- newAsyncVar
  liftIO $ mask_ $ do
    void $ forkIOWithUnmask $ \unmask -> do
      result <- try $ runOnResourceManager resourceManager (action (liftUnmask unmask))
      putAsyncVarEither_ resultVar result
    pure $ Task (toAwaitable resultVar)

liftUnmask :: (IO a -> IO a) -> AsyncIO a -> AsyncIO a
liftUnmask unmask action = do
  resourceManager <- askResourceManager
  liftIO $ unmask $ runOnResourceManager resourceManager action

await :: IsAwaitable r a => a -> AsyncIO r
-- TODO resource limits
await = liftIO . awaitIO


class MonadIO m => HasResourceManager m where
  askResourceManager :: m ResourceManager

instance HasResourceManager AsyncIO where
  askResourceManager = AsyncIO ask

instance MonadIO m => HasResourceManager (ReaderT ResourceManager m) where
  askResourceManager = ask


awaitResult :: IsAwaitable r a => AsyncIO a -> AsyncIO r
awaitResult = (await =<<)

data ResourceManager = ResourceManager {
  configuration :: ResourceManagerConfiguraiton,
  threads :: TVar (HashSet ThreadId)
}

instance IsDisposable ResourceManager where
  toDisposable x = undefined


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


data ResourceManagerConfiguraiton = ResourceManagerConfiguraiton {
  maxThreads :: Maybe Int
}

defaultResourceManagerConfiguration :: ResourceManagerConfiguraiton
defaultResourceManagerConfiguration = ResourceManagerConfiguraiton {
  maxThreads = Just 1
}

unlimitedResourceManagerConfiguration :: ResourceManagerConfiguraiton
unlimitedResourceManagerConfiguration = ResourceManagerConfiguraiton {
  maxThreads = Nothing
}

withResourceManager :: ResourceManagerConfiguraiton -> AsyncIO r -> IO r
withResourceManager configuration = bracket (newResourceManager configuration) disposeResourceManager . flip runOnResourceManager

runOnResourceManager :: ResourceManager -> AsyncIO r -> IO r
runOnResourceManager resourceManager (AsyncIO action) = runReaderT action resourceManager

withDefaultResourceManager :: AsyncIO a -> IO a
withDefaultResourceManager = withResourceManager defaultResourceManagerConfiguration

withUnlimitedResourceManager :: AsyncIO a -> IO a
withUnlimitedResourceManager = withResourceManager unlimitedResourceManagerConfiguration

newResourceManager :: ResourceManagerConfiguraiton -> IO ResourceManager
newResourceManager configuration = do
  threads <- newTVarIO mempty
  pure ResourceManager {
    configuration,
    threads
  }

disposeResourceManager :: ResourceManager -> IO ()
-- TODO resource management
disposeResourceManager = const (pure ())



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

data ListDisposable = ListDisposable [Disposable]

instance IsDisposable ListDisposable where
  dispose (ListDisposable disposables) = mconcat <$> traverse dispose disposables
  isDisposed (ListDisposable disposables) = traverse_ isDisposed disposables



data EmptyDisposable = EmptyDisposable

instance IsDisposable EmptyDisposable where
  dispose _ = pure $ pure ()
  isDisposed _ = successfulAwaitable ()



newDisposable :: IO (Awaitable ()) -> IO Disposable
newDisposable = fmap (toDisposable . FnDisposable) . newTMVarIO . Left

synchronousDisposable :: IO () -> IO Disposable
synchronousDisposable = newDisposable . fmap pure . liftIO

noDisposable :: Disposable
noDisposable = mempty

-- | Start disposing a resource but instead of waiting for the operation to complete, pass the responsibility to a `ResourceManager`.
--
-- The synchronous part of the `dispose`-Function will be run immediately but the resulting `Awaitable` will be passed to the resource manager.
disposeEventually :: (IsDisposable a, MonadIO m) => ResourceManager -> a -> m ()
disposeEventually resourceManager disposable = liftIO $ do
  disposeCompleted <- dispose disposable
  peekAwaitable disposeCompleted >>= \case
    Just (Left ex) -> throwIO ex
    Just (Right ()) -> pure ()
    Nothing -> undefined -- TODO register on resourceManager

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
boundDisposable :: HasResourceManager m => IO (Awaitable ()) -> m Disposable
boundDisposable action = do
  resourceManager <- askResourceManager
  attachDisposeAction resourceManager action

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m Disposable
attachDisposeAction = undefined

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m ()
attachDisposeAction_ resourceManager action = void $ attachDisposeAction resourceManager action
