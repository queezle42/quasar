module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  disposeAndAwait,
  newDisposable,
  synchronousDisposable,
  noDisposable,
  alreadyDisposing,

  -- ** ResourceManager
  ResourceManager,
  IsResourceManager(..),
  MonadResourceManager(..),
  withResourceManager,
  withOnResourceManager,
  newResourceManager,
  unsafeNewResourceManager,
  onResourceManager,
  attachDisposable,
  attachDisposeAction,
  attachDisposeAction_,
  disposeEventually,

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

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe (isJust)
import Data.Sequence
import Data.Sequence qualified as Seq
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


-- | Internal entry of `ResourceManager`. The `TMVar` will be set to `Nothing` when the disposable has completed disposing.
newtype ResourceManagerEntry = ResourceManagerEntry (TMVar (Awaitable (), Disposable))

instance IsAwaitable () ResourceManagerEntry where
  toAwaitable (ResourceManagerEntry var) = do
    varContents <- unsafeAwaitSTM $ tryReadTMVar var
    case varContents of
      -- If the var is empty the Entry has already been disposed
      Nothing -> pure ()
      Just (awaitable, _) -> awaitable


newEntry :: IsDisposable a => a -> IO ResourceManagerEntry
newEntry disposable = do
  disposedAwaitable <- cacheAwaitable (isDisposed disposable)
  ResourceManagerEntry <$> newTMVarIO (disposedAwaitable, toDisposable disposable)

entryStartDispose :: ResourceManagerEntry -> IO ()
entryStartDispose (ResourceManagerEntry var) =
  atomically (tryReadTMVar var) >>= \case
    Nothing -> pure ()
    Just (_, disposable) -> void $ dispose disposable

checkEntries :: Seq ResourceManagerEntry -> IO ()
checkEntries = mapM_ checkEntry

checkEntry :: ResourceManagerEntry -> IO ()
checkEntry (ResourceManagerEntry var) = do
  atomically (tryReadTMVar var) >>= \case
    Nothing -> pure ()
    Just (awaitable, _) -> do
      completed <- isJust <$> peekAwaitable awaitable
      when completed $ atomically $ void $ tryTakeTMVar var

entryIsEmpty :: ResourceManagerEntry -> STM Bool
entryIsEmpty (ResourceManagerEntry var) = isEmptyTMVar var


class IsResourceManager a where
  toResourceManager :: a -> ResourceManager
  -- TODO move to class
  --attachDisposable :: (IsDisposable b, MonadIO m) => a -> b -> m ()

instance IsResourceManager ResourceManager where
  toResourceManager = id

class (MonadAwait m, MonadMask m, MonadIO m) => MonadResourceManager m where
  registerDisposable :: IsDisposable a => a -> m ()

  registerDisposeAction :: IO (Awaitable ()) -> m ()
  registerDisposeAction disposeAction = mask_ $ registerDisposable =<< newDisposable disposeAction

  localResourceManager :: ResourceManager -> m a -> m a

  askResourceManager :: m ResourceManager

  -- TODO askResourceManager could maybe be replaced with
  --withRunResourceContextInIO :: (((forall f. MonadResourceManager f => f a) -> IO a) -> m b) -> m b


instance (MonadAwait m, MonadMask m, MonadIO m) => MonadResourceManager (ReaderT ResourceManager m) where
  registerDisposable disposable = do
    resourceManager <- ask
    attachDisposable resourceManager disposable

  localResourceManager resourceManager = local (const resourceManager)

  askResourceManager = ask


instance {-# OVERLAPPABLE #-} MonadResourceManager m => MonadResourceManager (ReaderT r m) where
  registerDisposable disposable = lift $ registerDisposable disposable

  localResourceManager resourceManager action = do
    x <- ask
    lift $ localResourceManager resourceManager $ runReaderT action x

  askResourceManager = lift askResourceManager



onResourceManager :: (IsResourceManager a) => a -> ReaderT ResourceManager m r -> m r
onResourceManager target action = runReaderT action (toResourceManager target)



data ResourceManager = ResourceManager {
  disposingVar :: TVar Bool,
  disposedVar :: TVar Bool,
  exceptionVar :: TMVar SomeException,
  entriesVar :: TVar (Seq ResourceManagerEntry)
}

instance IsDisposable ResourceManager where
  dispose resourceManager = liftIO $ mask \unmask ->
    unmask dispose' `catchAll` \ex -> setException resourceManager ex >> throwIO ex
    where
      dispose' :: IO (Awaitable ())
      dispose' = do
        entries <- atomically do
          isAlreadyDisposing <- swapTVar (disposingVar resourceManager) True
          if not isAlreadyDisposing
            then readTVar (entriesVar resourceManager)
            else pure Empty

        mapM_ entryStartDispose entries
        pure $ isDisposed resourceManager

  isDisposed resourceManager =
    unsafeAwaitSTM do
      (throwM =<< readTMVar (exceptionVar resourceManager))
        `orElse`
          ((\disposed -> unless disposed retry) =<< readTVar (disposedVar resourceManager))

withResourceManager :: (MonadAwait m, MonadMask m, MonadIO m) => (ResourceManager -> m a) -> m a
withResourceManager = bracket unsafeNewResourceManager (await <=< liftIO . dispose)

withOnResourceManager :: (MonadAwait m, MonadMask m, MonadIO m) => (ReaderT ResourceManager m a) -> m a
withOnResourceManager action = withResourceManager \resourceManager -> onResourceManager resourceManager action

newResourceManager :: MonadResourceManager m => m ResourceManager
newResourceManager = mask_ do
  resourceManager <- unsafeNewResourceManager
  registerDisposable resourceManager
  pure resourceManager

unsafeNewResourceManager :: MonadIO m => m ResourceManager
unsafeNewResourceManager = liftIO do
  disposingVar <- newTVarIO False
  disposedVar <- newTVarIO False
  exceptionVar <- newEmptyTMVarIO
  entriesVar <- newTVarIO Empty

  let resourceManager = ResourceManager {
    disposingVar,
    disposedVar,
    exceptionVar,
    entriesVar
  }

  void $ mask_ $ forkIOWithUnmask \unmask ->
    unmask (collectGarbage resourceManager) `catchAll` \ex -> setException resourceManager ex

  pure resourceManager


collectGarbage :: ResourceManager -> IO ()
collectGarbage resourceManager = go
  where
    go :: IO ()
    go = do
      snapshot <- atomically $ readTVar entriesVar'

      let listChanged = unsafeAwaitSTM do
            newLength <- Seq.length <$> readTVar entriesVar'
            when (newLength == Seq.length snapshot) retry

          isDisposing = unsafeAwaitSTM do
            disposing <- readTVar (disposingVar resourceManager)
            unless disposing retry

      -- Wait for any entry to complete or until a new entry is added
      let awaitables = (toAwaitable <$> toList snapshot)
      -- GC fails here when an waitable throws an exception
      void if Quasar.Prelude.null awaitables
        then awaitAny2 listChanged isDisposing
        else awaitAny (listChanged :| awaitables)

      -- Checking entries for completion has to be done in IO.
      -- Completion is then queried with `entryIsEmpty` during the following STM transaction.
      checkEntries =<< atomically (readTVar entriesVar')

      join $ atomically $ do
        disposing <- readTVar (disposingVar resourceManager)

        -- Filter completed entries
        allEntries <- readTVar entriesVar'
        filteredEntries <- foldM (\acc entry -> entryIsEmpty entry >>= \isEmpty -> pure if isEmpty then acc else acc |> entry) Empty allEntries
        writeTVar entriesVar' filteredEntries

        if disposing && Seq.null filteredEntries
           then do
             writeTVar (disposedVar resourceManager) True
             pure $ pure ()
           else pure go

    entriesVar' :: TVar (Seq ResourceManagerEntry)
    entriesVar' = entriesVar resourceManager


setException :: ResourceManager -> SomeException -> IO ()
setException resourceManager ex =
  -- TODO re-throw exception unchanged or wrap it?
  atomically $ void $ tryPutTMVar (exceptionVar resourceManager) ex



-- | Attaches an `Disposable` to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposable :: (IsDisposable a, MonadIO m) => ResourceManager -> a -> m ()
attachDisposable resourceManager disposable = liftIO $ mask \unmask -> do
  entry <- newEntry disposable

  join $ atomically do
    mapM_ throwM =<< tryReadTMVar (exceptionVar resourceManager)

    disposed <- readTVar (disposedVar resourceManager)
    when disposed $ throwM (userError "Cannot attach a disposable to a disposed resource manager")

    modifyTVar (entriesVar resourceManager) (|> entry)

    disposing <- readTVar (disposingVar resourceManager)

    pure do
      -- IO that is run after the STM transaction is completed
      when disposing $
        void $ unmask (dispose disposable) `catchAll` \ex -> setException resourceManager ex >> throwIO ex

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m Disposable
attachDisposeAction resourceManager action = liftIO $ mask_ $ do
  disposable <- newDisposable action
  attachDisposable resourceManager disposable
  pure disposable

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m ()
attachDisposeAction_ resourceManager action = void $ attachDisposeAction resourceManager action

-- | Start disposing a resource but instead of waiting for the operation to complete, pass the responsibility to a `ResourceManager`.
--
-- The synchronous part of the `dispose`-Function will be run immediately but the resulting `Awaitable` will be passed to the resource manager.
disposeEventually :: (IsDisposable a, MonadIO m) => ResourceManager -> a -> m ()
disposeEventually resourceManager disposable = liftIO $ do
  disposeCompleted <- dispose disposable
  peekAwaitable disposeCompleted >>= \case
    Just () -> pure ()
    Nothing -> attachDisposable resourceManager disposable






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
