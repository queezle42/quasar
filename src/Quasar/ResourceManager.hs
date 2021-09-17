module Quasar.ResourceManager (
  -- * MonadResourceManager
  MonadResourceManager(..),
  registerDisposable,
  registerDisposeAction,
  disposeEventually,
  withResourceManagerM,
  withSubResourceManagerM,
  onResourceManager,
  captureDisposable,
  captureTask,

  -- ** ResourceManager
  IsResourceManager(..),
  ResourceManager,
  withResourceManager,
  newResourceManager,
  newUnmanagedResourceManager,
  attachDisposable,
  attachDisposeAction,
  attachDisposeAction_,
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
import Quasar.Disposable
import Quasar.Prelude
import System.IO (hPutStrLn, stderr)



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

  --subResourceManager :: MonadResourceManager m => m (DisposableResourceThingy)

  throwToResourceManager :: Exception e => a -> e -> IO ()
  throwToResourceManager = throwToResourceManager . toResourceManager


instance IsResourceManager ResourceManager where
  toResourceManager = id
  -- TODO delegate to parent
  throwToResourceManager _ ex = hPutStrLn stderr $ displayException ex

class (MonadAwait m, MonadMask m, MonadIO m) => MonadResourceManager m where
  -- | Get the underlying resource manager.
  askResourceManager :: m ResourceManager

  -- | Replace the resource manager for a computation.
  localResourceManager :: IsResourceManager a => a -> m r -> m r


registerDisposable :: (IsDisposable a, MonadResourceManager m) => a -> m ()
registerDisposable disposable = do
  resourceManager <- askResourceManager
  attachDisposable resourceManager disposable


registerDisposeAction :: MonadResourceManager m => IO (Awaitable ()) -> m ()
registerDisposeAction disposeAction = mask_ $ registerDisposable =<< newDisposable disposeAction


withSubResourceManagerM :: MonadResourceManager m => m a -> m a
withSubResourceManagerM action =
  bracket newResourceManager (await <=< dispose) \scope -> localResourceManager scope action


instance (MonadAwait m, MonadMask m, MonadIO m) => MonadResourceManager (ReaderT ResourceManager m) where
  localResourceManager resourceManager = local (const (toResourceManager resourceManager))

  askResourceManager = ask


instance {-# OVERLAPPABLE #-} MonadResourceManager m => MonadResourceManager (ReaderT r m) where
  askResourceManager = lift askResourceManager

  localResourceManager resourceManager action = do
    x <- ask
    lift $ localResourceManager resourceManager $ runReaderT action x


-- TODO MonadResourceManager instances for StateT, WriterT, RWST, MaybeT, ...


onResourceManager :: (IsResourceManager a) => a -> ReaderT ResourceManager m r -> m r
onResourceManager target action = runReaderT action (toResourceManager target)


captureTask :: MonadResourceManager m => m (Awaitable a) -> m (Task a)
captureTask action = do
  -- TODO improve performance by only creating a new resource manager when two or more disposables are attached
  resourceManager <- newResourceManager
  awaitable <- localResourceManager resourceManager action
  pure $ Task (toDisposable resourceManager) awaitable

captureDisposable :: MonadResourceManager m => m () -> m Disposable
captureDisposable action = do
  -- TODO improve performance by only creating a new resource manager when two or more disposables are attached
  resourceManager <- newResourceManager
  localResourceManager resourceManager action
  pure $ toDisposable resourceManager



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
withResourceManager = bracket newUnmanagedResourceManager (await <=< liftIO . dispose)

withResourceManagerM :: (MonadAwait m, MonadMask m, MonadIO m) => (ReaderT ResourceManager m a) -> m a
withResourceManagerM action = withResourceManager \resourceManager -> onResourceManager resourceManager action

newResourceManager :: MonadResourceManager m => m ResourceManager
newResourceManager = mask_ do
  resourceManager <- newUnmanagedResourceManager
  registerDisposable resourceManager
  pure resourceManager

newUnmanagedResourceManager :: MonadIO m => m ResourceManager
newUnmanagedResourceManager = liftIO do
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

-- | Start disposing a resource but instead of waiting for the operation to complete, pass the responsibility to a
-- `MonadResourceManager`.
--
-- The synchronous part of the `dispose`-Function will be run immediately but the resulting `Awaitable` will be passed
-- to the resource manager.
disposeEventually :: (IsDisposable a, MonadResourceManager m) => a -> m ()
disposeEventually disposable = do
  disposeCompleted <- dispose disposable
  peekAwaitable disposeCompleted >>= \case
    Just () -> pure ()
    Nothing -> registerDisposable disposable
