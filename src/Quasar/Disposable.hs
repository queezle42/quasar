module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  disposeIO,
  newDisposable,
  synchronousDisposable,
  noDisposable,

  -- ** ResourceManager
  ResourceManager,
  HasResourceManager(..),
  withResourceManager,
  newResourceManager,
  attachDisposable,
  attachDisposeAction,
  attachDisposeAction_,
  disposeEventually,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Quasar.Awaitable
import Quasar.Prelude


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

  cacheAwaitable = cacheAwaitableDefaultImplementation



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

withResourceManager :: (ResourceManager -> IO a) -> IO a
withResourceManager = bracket newResourceManager (awaitIO <=< dispose)

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
attachDisposable _resourceManager disposable = liftIO undefined

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m Disposable
attachDisposeAction resourceManager action = do
  disposable <- newDisposable action
  attachDisposable resourceManager disposable
  pure disposable

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m ()
attachDisposeAction_ resourceManager action = void $ attachDisposeAction resourceManager action
