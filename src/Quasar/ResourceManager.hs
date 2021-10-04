module Quasar.ResourceManager (
  -- * MonadResourceManager
  MonadResourceManager(..),
  FailedToRegisterResource,
  registerNewResource,
  registerDisposable,
  registerDisposeAction,
  registerSimpleDisposeAction,
  disposeEventually,
  withSubResourceManagerM,
  onResourceManager,
  captureDisposable,
  captureDisposable_,
  captureTask,

  -- ** ResourceManager
  IsResourceManager(..),
  ResourceManager,
  newResourceManager,
  attachDisposeAction,
  attachDisposeAction_,

  -- ** Initialization
  withRootResourceManager,

  CancelLinkedThread,

  -- ** Resource manager implementations
  newUnmanagedRootResourceManager,
  --newUnmanagedDefaultResourceManager,
) where


import Control.Concurrent (ThreadId, forkIOWithUnmask, myThreadId, throwTo, forkIO)
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
import System.IO (fixIO, hPutStrLn, stderr)


data FailedToRegisterResource = FailedToRegisterResource
  deriving stock (Eq, Show)

instance Exception FailedToRegisterResource where
  displayException FailedToRegisterResource =
    "FailedToRegisterResource: Failed to register a resource to a resource manager. This might result in leaked resources if left unhandled."

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


class IsDisposable a => IsResourceManager a where
  toResourceManager :: a -> ResourceManager
  toResourceManager = ResourceManager

  -- | Attaches an `Disposable` to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
  attachDisposable :: (IsDisposable b, MonadIO m) => a -> b -> m ()
  attachDisposable self = attachDisposable (toResourceManager self)

  --subResourceManager :: MonadResourceManager m => m (DisposableResourceThingy)

  -- | Forward an exception that happened asynchronously.
  throwToResourceManager :: Exception e => a -> e -> IO ()
  throwToResourceManager = throwToResourceManager . toResourceManager

  {-# MINIMAL toResourceManager | (attachDisposable, throwToResourceManager) #-}


data ResourceManager = forall a. IsResourceManager a => ResourceManager a
instance IsResourceManager ResourceManager where
  toResourceManager = id
  attachDisposable (ResourceManager x) = attachDisposable x
  throwToResourceManager (ResourceManager x) = throwToResourceManager x
instance IsDisposable ResourceManager where
  toDisposable (ResourceManager x) = toDisposable x

class (MonadAwait m, MonadMask m, MonadIO m, MonadFix m) => MonadResourceManager m where
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

registerSimpleDisposeAction :: MonadResourceManager m => IO () -> m ()
registerSimpleDisposeAction disposeAction = registerDisposeAction (pure () <$ disposeAction)

registerNewResource :: (IsDisposable a, MonadResourceManager m) => m a -> m a
registerNewResource action = mask_ do
  afix \awaitable -> do
    registerDisposeAction $ either (\(_ :: SomeException) -> mempty) dispose =<< try (await awaitable)
    action


-- TODO rename to withResourceScope?
withSubResourceManagerM :: MonadResourceManager m => m a -> m a
withSubResourceManagerM action =
  bracket newResourceManager (await <=< dispose) \scope -> localResourceManager scope action


instance (MonadAwait m, MonadMask m, MonadIO m, MonadFix m) => MonadResourceManager (ReaderT ResourceManager m) where
  localResourceManager resourceManager = local (const (toResourceManager resourceManager))

  askResourceManager = ask


instance {-# OVERLAPPABLE #-} MonadResourceManager m => MonadResourceManager (ReaderT r m) where
  askResourceManager = lift askResourceManager

  localResourceManager resourceManager action = do
    x <- ask
    lift $ localResourceManager resourceManager $ runReaderT action x


-- TODO MonadResourceManager instances for StateT, WriterT, RWST, MaybeT, ...


onResourceManager :: (IsResourceManager a, MonadIO m) => a -> ReaderT ResourceManager IO r -> m r
onResourceManager target action = liftIO $ runReaderT action (toResourceManager target)


captureDisposable :: MonadResourceManager m => m a -> m (a, Disposable)
captureDisposable action = do
  -- TODO improve performance by only creating a new resource manager when two or more disposables are attached
  resourceManager <- newResourceManager
  result <- localResourceManager resourceManager action
  pure $ (result, toDisposable resourceManager)

captureDisposable_ :: MonadResourceManager m => m () -> m Disposable
captureDisposable_ = snd <<$>> captureDisposable

captureTask :: MonadResourceManager m => m (Awaitable a) -> m (Task a)
captureTask action = do
  (awaitable, disposable) <- captureDisposable action
  pure $ Task disposable awaitable


-- * ExceptionHandler

type ExceptionHandler = SomeException -> IO ()

loggingExceptionHandler :: ExceptionHandler
loggingExceptionHandler ex = traceIO $ displayException ex


-- | A computation bound to a resource manager with 'linkThread' should be canceled.
data CancelLinkedThread = CancelLinkedThread Unique
  deriving anyclass Exception

instance Show CancelLinkedThread where
  show _ = "CancelLinkedThread"


data LinkState = LinkStateLinked ThreadId | LinkStateThrowing | LinkStateCompleted
  deriving Eq


-- * Resource manager implementations


newtype CombinedException = CombinedException [SomeException]

data RootResourceManager = RootResourceManager ResourceManager ExceptionHandler

instance IsResourceManager RootResourceManager where
  attachDisposable (RootResourceManager child _) disposable = attachDisposable child disposable
  throwToResourceManager (RootResourceManager child exceptionHandler) ex = do
    exceptionHandler (toException ex)
    void $ dispose child

instance IsDisposable RootResourceManager where
  dispose (RootResourceManager child _) = dispose child
  isDisposed (RootResourceManager child _) = isDisposed child

withRootResourceManager :: (MonadAwait m, MonadMask m, MonadIO m) => ReaderT ResourceManager IO a -> m a
withRootResourceManager action =
  bracket
    newUnmanagedRootResourceManager
    (await <=< liftIO . dispose)
    (`onResourceManager` action)


newUnmanagedRootResourceManager :: MonadIO m => m ResourceManager
newUnmanagedRootResourceManager = liftIO $ fixIO \self -> do
  var <- liftIO newEmptyTMVarIO
  childResourceManager <- newUnmanagedDefaultResourceManager self
  pure $ toResourceManager (RootResourceManager childResourceManager loggingExceptionHandler)


data DefaultResourceManager = DefaultResourceManager {
  parentResourceManager :: ResourceManager,
  disposingVar :: TVar Bool,
  disposedVar :: TVar Bool,
  entriesVar :: TVar (Seq ResourceManagerEntry)
}

instance IsResourceManager DefaultResourceManager where
  throwToResourceManager DefaultResourceManager{parentResourceManager} = throwToResourceManager parentResourceManager

  attachDisposable resourceManager disposable = liftIO $ mask_ do
    entry <- newEntry disposable

    join $ atomically do
      disposing <- readTVar (disposingVar resourceManager)
      disposed <- readTVar (disposedVar resourceManager)

      unless disposing $ modifyTVar (entriesVar resourceManager) (|> entry)

      pure do
        -- IO that is run after the STM transaction is completed
        when disposing $
          throwM FailedToRegisterResource `catchAll` throwToResourceManager resourceManager

instance IsDisposable DefaultResourceManager where
  dispose resourceManager = liftIO $ mask_ do
    entries <- atomically do
      isAlreadyDisposing <- swapTVar (disposingVar resourceManager) True
      if not isAlreadyDisposing
        then readTVar (entriesVar resourceManager)
        else pure Empty

    mapM_ entryStartDispose entries
    pure $ isDisposed resourceManager
    where
      entryStartDispose :: ResourceManagerEntry -> IO ()
      entryStartDispose (ResourceManagerEntry var) =
        atomically (tryReadTMVar var) >>= \case
          Nothing -> pure ()
          Just (_, disposable) ->
            catchAll
              do void (dispose disposable)
              \ex -> do
                -- Disposable failed so it should be removed
                atomically (void $ tryTakeTMVar var)
                throwToResourceManager resourceManager ex
                pure ()


  isDisposed resourceManager =
    unsafeAwaitSTM do
      disposed <- readTVar (disposedVar resourceManager)
      unless disposed retry

newResourceManager :: MonadResourceManager m => m ResourceManager
newResourceManager = mask_ do
  parent <- askResourceManager
  -- TODO: return efficent resource manager
  resourceManager <- newUnmanagedDefaultResourceManager parent
  registerDisposable resourceManager
  pure resourceManager

newUnmanagedDefaultResourceManager :: MonadIO m => ResourceManager -> m ResourceManager
newUnmanagedDefaultResourceManager parentResourceManager = liftIO do
  disposingVar <- newTVarIO False
  disposedVar <- newTVarIO False
  entriesVar <- newTVarIO Empty

  let resourceManager = DefaultResourceManager {
    parentResourceManager,
    disposingVar,
    disposedVar,
    entriesVar
  }

  void $ mask_ $ forkIOWithUnmask \unmask ->
    unmask (freeGarbage resourceManager) `catchAll` throwToResourceManager resourceManager

  pure $ toResourceManager resourceManager


freeGarbage :: DefaultResourceManager -> IO ()
freeGarbage resourceManager = go
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
