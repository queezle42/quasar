module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  disposeAndAwait,
  newDisposable,
  synchronousDisposable,
  noDisposable,
  alreadyDisposing,

  -- * Task
  Task(..),
  cancelTask,
  toTask,
  completedTask,
  successfulTask,
  failedTask,

  -- ** Task exceptions
  CancelTask(..),
  TaskDisposed(..),
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
  -- TODO MonadIO
  dispose :: MonadIO m => a -> m (Awaitable ())
  dispose = dispose . toDisposable

  isDisposed :: a -> Awaitable ()
  isDisposed = isDisposed . toDisposable

  toDisposable :: a -> Disposable
  toDisposable = Disposable

  {-# MINIMAL toDisposable | (dispose, isDisposed) #-}


disposeAndAwait :: (MonadAwait m, MonadIO m) => IsDisposable a => a -> m ()
disposeAndAwait disposable = await =<< liftIO (dispose disposable)



instance IsDisposable a => IsDisposable (Maybe a) where
  toDisposable = maybe noDisposable toDisposable



data Disposable = forall a. IsDisposable a => Disposable a

instance IsDisposable Disposable where
  dispose (Disposable x) = dispose x
  isDisposed (Disposable x) = isDisposed x
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
  dispose (FnDisposable var) = liftIO do
    mask \restore -> do
      eitherVal <- atomically do
        takeTMVar var >>= \case
          l@(Left _action) -> pure l
          -- If the var contains an awaitable its put back immediately to save a second transaction
          r@(Right _awaitable) -> r <$ putTMVar var r
      case eitherVal of
        l@(Left action) -> do
          awaitable <- restore action `onException` atomically (putTMVar var l)
          atomically $ putTMVar var $ Right awaitable
          pure awaitable
        Right awaitable -> pure awaitable

  isDisposed = toAwaitable

instance IsAwaitable () FnDisposable where
  toAwaitable :: FnDisposable -> Awaitable ()
  toAwaitable (FnDisposable var) =
    join $ unsafeAwaitSTM do
      state <- readTMVar var
      case state of
        -- Wait until disposing has been started
        Left _ -> retry
        -- Wait for disposing to complete
        Right awaitable -> pure awaitable


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
  isDisposed _ = pure ()



-- | Create a new disposable from an IO action. Is is guaranteed, that the IO action will only be called once (even when
-- `dispose` is called multiple times).
newDisposable :: MonadIO m => IO (Awaitable ()) -> m Disposable
newDisposable action = liftIO $ toDisposable . FnDisposable <$> newTMVarIO (Left action)

-- | Create a new disposable from an IO action. Is is guaranteed, that the IO action will only be called once (even when
-- `dispose` is called multiple times).
synchronousDisposable :: MonadIO m => IO () -> m Disposable
synchronousDisposable = newDisposable . fmap pure

noDisposable :: Disposable
noDisposable = mempty


newtype AlreadyDisposing = AlreadyDisposing (Awaitable ())

instance IsDisposable AlreadyDisposing where
  dispose x = pure (isDisposed x)
  isDisposed (AlreadyDisposing awaitable) = awaitable

-- | Create a `Disposable` from an `IsAwaitable`.
--
-- The disposable is considered to be already disposing (so `dispose` will be a no-op) and is considered disposed once
-- the awaitable is completed.
alreadyDisposing :: IsAwaitable () a => a -> Disposable
alreadyDisposing someAwaitable = toDisposable $ AlreadyDisposing $ toAwaitable someAwaitable








-- | A task is an operation (e.g. a thread or a network request) that is running asynchronously and can be cancelled.
-- It has a result and can fail.
--
-- The result (or exception) can be aquired by using the `IsAwaitable` class (e.g. by calling `await` or `awaitIO`).
-- It is possible to cancel the task by using `dispose` or `cancelTask` if the operation has not been completed.
data Task r = Task Disposable (Awaitable r)

instance IsAwaitable r (Task r) where
  toAwaitable (Task _ awaitable) = awaitable

instance IsDisposable (Task r) where
  toDisposable (Task disposable _) = disposable

instance Functor Task where
  fmap fn (Task disposable awaitable) = Task disposable (fn <$> awaitable)

instance Applicative Task where
  pure value = Task noDisposable (pure value)
  liftA2 fn (Task dx fx) (Task dy fy) = Task (dx <> dy) $ liftA2 fn fx fy

-- | Alias for `dispose`.
cancelTask :: Task r -> IO (Awaitable ())
cancelTask = dispose

-- | Creates an `Task` from an `Awaitable`.
-- The resulting task only depends on an external resource, so disposing it has no effect.
toTask :: IsAwaitable r a => a -> Task r
toTask result = Task noDisposable (toAwaitable result)

completedTask :: Either SomeException r -> Task r
completedTask result = Task noDisposable (completedAwaitable result)

-- | Alias for `pure`
successfulTask :: r -> Task r
successfulTask = pure

failedTask :: SomeException -> Task r
failedTask ex = Task noDisposable (failedAwaitable ex)



data CancelTask = CancelTask
  deriving stock Show
instance Exception CancelTask where

data TaskDisposed = TaskDisposed
  deriving stock Show
instance Exception TaskDisposed where
