module Quasar.ResourceManager (
  -- * MonadResourceManager
  MonadResourceManager(..),
  ResourceManagerT,
  ResourceManagerIO,
  ResourceManagerSTM,
  FailedToRegisterResource,
  attachDisposable,
  registerNewResource,
  registerNewResource_,
  registerDisposable,
  registerDisposeAction,
  registerAsyncDisposeAction,
  throwToResourceManager,
  withScopedResourceManager,
  onResourceManager,
  onResourceManagerSTM,
  captureDisposable,
  captureDisposable_,
  disposeOnError,
  liftResourceManagerIO,
  runInResourceManagerSTM,
  enterResourceManager,
  enterResourceManagerSTM,
  newUniqueRM,

  -- ** Top level initialization
  withRootResourceManager,

  -- ** ResourceManager
  IsResourceManager(..),
  ResourceManager,
  newResourceManager,
  newResourceManagerSTM,
  attachDisposeAction,
  attachDisposeAction_,

  -- ** Linking computations to a resource manager
  linkExecution,
  CancelLinkedExecution,

  -- * Reexports
  CombinedException,
  combinedExceptions,
) where


import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo, threadDelay)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.List.NonEmpty ((<|), nonEmpty)
import Data.Sequence (Seq(..), (|>))
import Data.Sequence qualified as Seq
import Quasar.Async.Unmanaged
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.Exceptions


data FailedToRegisterResource = FailedToRegisterResource
  deriving stock (Eq, Show)

instance Exception FailedToRegisterResource where
  displayException FailedToRegisterResource =
    "FailedToRegisterResource: Failed to register a resource to a resource manager. This might result in leaked resources if left unhandled."

data FailedToLockResourceManager = FailedToLockResourceManager
  deriving stock (Eq, Show)

instance Exception FailedToLockResourceManager where
  displayException FailedToLockResourceManager =
    "FailedToLockResourceManager: Failed to lock a resource manager."

-- TODO HasResourceManager, getResourceManager
class IsDisposable a => IsResourceManager a where
  toResourceManager :: a -> ResourceManager


class MonadFix m => MonadResourceManager m where
  -- | Get the underlying resource manager.
  askResourceManager :: m ResourceManager

  -- | Replace the resource manager for a computation.
  localResourceManager :: IsResourceManager a => a -> m r -> m r

  -- | Locks the resource manager. As long as the resource manager is locked, it's possible to register new resources
  -- on the resource manager.
  --
  -- This prevents the resource manager from disposing, so the computation must not block for an unbound amount of time.
  lockResourceManager :: MonadResourceManager m => m a -> m a

  -- | Run an `STM` computation. Depending on the monad this may be run in a dedicated STM transaction or may be
  -- embedded in a larger transaction.
  runInSTM :: MonadResourceManager m => STM a -> m a

  maskIfRequired :: MonadResourceManager m => m a -> m a


-- | Forward an exception that happened asynchronously.
throwToResourceManager :: (Exception e, MonadResourceManager m) => e -> m ()
throwToResourceManager ex = do
  resourceManager <- askResourceManager
  runInSTM $ throwToResourceManagerImpl resourceManager (toException ex)


runInResourceManagerSTM :: MonadResourceManager m => ResourceManagerSTM a -> m a
runInResourceManagerSTM action = do
  resourceManager <- askResourceManager
  runInSTM $ runReaderT action resourceManager

-- | Register a `Disposable` to the resource manager.
--
-- May throw an `FailedToRegisterResource` if the resource manager is disposing/disposed.
registerDisposable :: (IsDisposable a, MonadResourceManager m) => a -> m ()
registerDisposable disposable = do
  resourceManager <- askResourceManager
  runInSTM $ attachDisposable resourceManager disposable


registerDisposeAction :: MonadResourceManager m => IO () -> m ()
registerDisposeAction disposeAction = runInResourceManagerSTM do
  disposable <- lift (newDisposable disposeAction)
  registerDisposable disposable

registerAsyncDisposeAction :: MonadResourceManager m => IO () -> m ()
registerAsyncDisposeAction disposeAction = runInResourceManagerSTM do
  disposable <- lift (newAsyncDisposable disposeAction)
  registerDisposable disposable

-- | Locks the resource manager (which may fail), runs the computation and registeres the resulting disposable.
--
-- The computation will be run in masked state (if not running atomically in `STM`).
--
-- The computation must not block for an unbound amount of time.
registerNewResource :: (IsDisposable a, MonadResourceManager m) => m a -> m a
registerNewResource action = maskIfRequired $ lockResourceManager do
    resource <- action
    registerDisposable resource
    pure resource

registerNewResource_ :: (IsDisposable a, MonadResourceManager m) => m a -> m ()
registerNewResource_ action = void $ registerNewResource action

withScopedResourceManager :: (MonadResourceManager m, MonadIO m, MonadMask m) => m a -> m a
withScopedResourceManager action =
  bracket newResourceManager dispose \scope -> localResourceManager scope action


type ResourceManagerT = ReaderT ResourceManager
type ResourceManagerIO = ResourceManagerT IO
type ResourceManagerSTM = ResourceManagerT STM

instance (MonadAwait m, MonadMask m, MonadIO m, MonadFix m) => MonadResourceManager (ResourceManagerT m) where
  localResourceManager resourceManager = local (const (toResourceManager resourceManager))

  askResourceManager = ask

  lockResourceManager action = do
    resourceManager <- askResourceManager
    lockResourceManagerImpl resourceManager action

  runInSTM action = liftIO $ atomically action

  maskIfRequired = mask_


-- Overlaps the ResourceManagerT/MonadIO-instance, because `MonadIO` _could_ be specified for `STM` (but that would be
-- _very_ incorrect, so this is safe).
instance {-# OVERLAPS #-} MonadResourceManager (ResourceManagerT STM) where
  localResourceManager resourceManager = local (const (toResourceManager resourceManager))

  askResourceManager = ask

  -- | No-op, since STM is always executed atomically.
  lockResourceManager = id

  runInSTM action = lift action

  maskIfRequired = id


instance {-# OVERLAPPABLE #-} MonadResourceManager m => MonadResourceManager (ReaderT r m) where
  askResourceManager = lift askResourceManager

  localResourceManager resourceManager action = do
    x <- ask
    lift $ localResourceManager resourceManager $ runReaderT action x

  lockResourceManager action = do
    x <- ask
    lift $ lockResourceManager $ runReaderT action x

  runInSTM action = lift $ runInSTM action

  maskIfRequired action = do
    x <- ask
    lift $ maskIfRequired $ runReaderT action x

-- TODO MonadResourceManager instances for StateT, WriterT, RWST, MaybeT, ...


onResourceManager :: (IsResourceManager a, MonadIO m) => a -> ResourceManagerIO r -> m r
onResourceManager target action = liftIO $ runReaderT action (toResourceManager target)

onResourceManagerSTM :: (IsResourceManager a) => a -> ResourceManagerSTM r -> STM r
onResourceManagerSTM target action = runReaderT action (toResourceManager target)

liftResourceManagerIO :: (MonadResourceManager m, MonadIO m) => ResourceManagerIO r -> m r
liftResourceManagerIO action = do
  resourceManager <- askResourceManager
  onResourceManager resourceManager action


captureDisposable :: MonadResourceManager m => m a -> m (a, Disposable)
captureDisposable action = do
  resourceManager <- newResourceManager
  result <- localResourceManager resourceManager action
  pure (result, toDisposable resourceManager)

captureDisposable_ :: MonadResourceManager m => m () -> m Disposable
captureDisposable_ = snd <<$>> captureDisposable

-- | Disposes all resources created by the computation if the computation throws an exception.
disposeOnError :: (MonadResourceManager m, MonadIO m, MonadMask m) => m a -> m a
disposeOnError action = do
  bracketOnError
    newResourceManager
    dispose
    \resourceManager -> localResourceManager resourceManager action

-- | Run a computation on a resource manager and throw any exception that occurs to the resource manager.
--
-- This can be used to run e.g. callbacks that belong to a different resource context.
--
-- Locks the resource manager, so the computation must not block for an unbounded time.
--
-- May throw an exception when the resource manager is disposing.
enterResourceManager :: MonadIO m => ResourceManager -> ResourceManagerIO () -> m ()
enterResourceManager resourceManager action = liftIO do
  onResourceManager resourceManager $ lockResourceManager do
    action `catchAll` \ex -> throwToResourceManager ex

-- | Run a computation on a resource manager and throw any exception that occurs to the resource manager.
--
-- This can be used to run e.g. callbacks that belong to a different resource context.
enterResourceManagerSTM :: ResourceManager -> ResourceManagerSTM () -> STM ()
enterResourceManagerSTM resourceManager action = do
  onResourceManagerSTM resourceManager do
    action `catchAll` \ex -> throwToResourceManager ex


-- | Create a new `Unique` in a `MonadResourceManager` monad.
newUniqueRM :: MonadResourceManager m => m Unique
newUniqueRM = runInSTM newUniqueSTM



-- * Resource manager implementations

-- ** Root resource manager

data ResourceManager
  = NormalResourceManager ResourceManagerCore ResourceManager
  | RootResourceManager ResourceManagerCore (TVar Bool) (TMVar (Seq SomeException)) (AsyncVar [SomeException])


instance IsResourceManager ResourceManager where
  toResourceManager = id

resourceManagerCore :: ResourceManager -> ResourceManagerCore
resourceManagerCore (RootResourceManager core _ _ _) = core
resourceManagerCore (NormalResourceManager core _) = core

throwToResourceManagerImpl :: ResourceManager -> SomeException -> STM ()
throwToResourceManagerImpl (NormalResourceManager _ exceptionManager) ex = throwToResourceManagerImpl exceptionManager ex
throwToResourceManagerImpl (RootResourceManager _ _ exceptionsVar _) ex = do
  tryTakeTMVar exceptionsVar >>= \case
    Just exceptions -> do
      putTMVar exceptionsVar (exceptions |> toException ex)
    Nothing -> do
      throwM $ userError "Could not throw to resource manager: RootResourceManager is already disposed"



instance IsDisposable ResourceManager where
  beginDispose (NormalResourceManager core _) = beginDispose core
  beginDispose (RootResourceManager internal disposingVar _ _) = do
    defaultResourceManagerDisposeResult internal <$ atomically do
      disposing <- readTVar disposingVar
      unless disposing $ writeTVar disposingVar True

  isDisposed (resourceManagerCore -> core) = isDisposed core

  registerFinalizer (resourceManagerCore -> core) = registerFinalizer core

newUnmanagedRootResourceManagerInternal :: MonadIO m => m ResourceManager
newUnmanagedRootResourceManagerInternal = liftIO do
  disposingVar <- newTVarIO False
  exceptionsVar <- newTMVarIO Empty
  finalExceptionsVar <- newAsyncVar
  mfix \root -> do
    void $ forkIO (disposeWorker root)
    internal <- atomically $ newUnmanagedDefaultResourceManagerInternal (throwToResourceManagerImpl root)
    pure $ RootResourceManager internal disposingVar exceptionsVar finalExceptionsVar
  where
    disposeWorker :: ResourceManager -> IO ()
    disposeWorker (NormalResourceManager _ _) = unreachableCodePathM
    disposeWorker (RootResourceManager internal disposingVar exceptionsVar finalExceptionsVar) =
      handleAll
        do \ex -> fail $ "RootResourceManager thread failed unexpectedly: " <> displayException ex
        do
          -- Wait until disposing
          atomically do
            disposing <- readTVar disposingVar
            hasExceptions <- not . Seq.null <$> readTMVar exceptionsVar
            check $ disposing || hasExceptions

          -- Start a thread to report exceptions (or a potential hang) after a timeout
          reportThread <- unmanagedAsync reportTimeout

          -- Dispose resources
          dispose internal

          atomically do
            -- The var is set to `Nothing` to signal that no more exceptions can be received
            exceptions <- takeTMVar exceptionsVar

            putAsyncVarSTM_ finalExceptionsVar $ toList exceptions

          -- Clean up timeout/report thread
          dispose reportThread

      where
        timeoutSeconds :: Int
        timeoutSeconds = 5
        timeoutMicroseconds :: Int
        timeoutMicroseconds = timeoutSeconds * 1_000_000

        reportTimeout :: IO ()
        reportTimeout = do
          threadDelay timeoutMicroseconds
          atomically (tryReadTMVar exceptionsVar) >>= \case
            Nothing -> pure () -- Terminate
            Just Empty -> do
              traceIO $ mconcat ["Root resource manager did not dispose within ", show timeoutSeconds, " seconds"]
              reportExceptions 0 Empty
            Just exs -> do
              traceIO $ mconcat [ "Root resource manager did not dispose within ",
                show timeoutSeconds, " seconds (", show (length exs), " exception(s) queued)" ]
              reportExceptions 0 exs

        reportExceptions :: Int -> Seq SomeException -> IO ()
        reportExceptions alreadyReported Empty = join $ atomically do
          Seq.drop alreadyReported <<$>> tryReadTMVar exceptionsVar >>= \case
            Nothing -> pure $ pure () -- Terminate
            Just Empty -> retry
            Just exs -> pure $ reportExceptions alreadyReported exs
        reportExceptions alreadyReported (ex :<| exs) = do
          traceIO $ "Exception thrown to blocked root resource manager: " <> displayException ex
          reportExceptions (alreadyReported + 1) exs


withRootResourceManager :: MonadIO m => ResourceManagerIO a -> m a
withRootResourceManager action = liftIO $ uninterruptibleMask \unmask -> do
  resourceManager@(RootResourceManager _ _ _ finalExceptionsVar) <- newUnmanagedRootResourceManagerInternal

  result <- try $ unmask $ onResourceManager resourceManager action

  disposeEventually_ resourceManager
  exceptions <- await finalExceptionsVar

  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right result' -> maybe (pure result') (throwM . CombinedException) $ nonEmpty exceptions


-- ** Default resource manager

data ResourceManagerCore = ResourceManagerCore {
  resourceManagerKey :: Unique,
  throwToHandler :: SomeException -> STM (),
  stateVar :: TVar ResourceManagerState,
  disposablesVar :: TMVar (HashMap Unique Disposable),
  lockVar :: TVar Word64,
  resultVar :: AsyncVar (Awaitable [ResourceManagerResult]),
  finalizers :: DisposableFinalizers
}

data ResourceManagerState
  = ResourceManagerNormal
  | ResourceManagerDisposing
  | ResourceManagerDisposed


-- | Attaches an `Disposable` to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
--
-- May throw an `FailedToRegisterResource` if the resource manager is disposing/disposed.
attachDisposable :: (IsResourceManager a, IsDisposable b) => a -> b -> STM ()
attachDisposable rm disposable = attachDisposableImpl (resourceManagerCore (toResourceManager rm)) (toDisposable disposable)

attachDisposableImpl :: ResourceManagerCore -> Disposable -> STM ()
attachDisposableImpl ResourceManagerCore{stateVar, disposablesVar} disposable = do
  key <- newUniqueSTM
  state <- readTVar stateVar
  case state of
    ResourceManagerNormal -> do
      disposables <- takeTMVar disposablesVar
      putTMVar disposablesVar (HM.insert key disposable disposables)
      void $ registerFinalizer disposable (finalizer key)
    _ -> throwM FailedToRegisterResource
  where
    finalizer :: Unique -> STM ()
    finalizer key =
      tryTakeTMVar disposablesVar >>= \case
        Just disposables ->
          putTMVar disposablesVar $ HM.delete key disposables
        Nothing -> pure ()

lockResourceManagerImpl :: (MonadIO m, MonadMask m) => ResourceManager -> m b -> m b
lockResourceManagerImpl (resourceManagerCore -> ResourceManagerCore{stateVar, lockVar}) =
  bracket_ (liftIO aquire) (liftIO release)
  where
    aquire :: IO ()
    aquire = atomically do
      readTVar stateVar >>= \case
        ResourceManagerNormal -> pure ()
        _ -> throwM FailedToLockResourceManager
      modifyTVar lockVar (+ 1)
    release :: IO ()
    release = atomically (modifyTVar lockVar (\x -> x - 1))

instance IsDisposable ResourceManagerCore where
  beginDispose self@ResourceManagerCore{resourceManagerKey, throwToHandler, stateVar, disposablesVar, lockVar, resultVar, finalizers} = liftIO do
    uninterruptibleMask_ do
      join $ atomically do
        state <- readTVar stateVar
        case state of
          ResourceManagerNormal -> do
            writeTVar stateVar ResourceManagerDisposing
            readTVar lockVar >>= \case
              0 -> do
                disposables <- takeDisposables
                pure (primaryBeginDispose disposables)
              _ -> pure primaryForkDisposeThread
          ResourceManagerDisposing -> pure $ pure $ defaultResourceManagerDisposeResult self
          ResourceManagerDisposed -> pure $ pure DisposeResultDisposed
    where
      primaryForkDisposeThread :: IO DisposeResult
      primaryForkDisposeThread = forkDisposeThread do
        disposables <- atomically do
          check =<< (== 0) <$> readTVar lockVar
          takeDisposables
        void $ primaryBeginDispose disposables

      -- Only one thread enters this function (in uninterruptible masked state)
      primaryBeginDispose :: [Disposable] -> IO DisposeResult
      primaryBeginDispose disposables = do
        (reportExceptionActions, resultAwaitables) <- unzip <$> mapM beginDisposeEntry disposables
        -- TODO cache was removed, has to be re-optimized later
        let cachedResultAwaitable = mconcat resultAwaitables
        putAsyncVar_ resultVar cachedResultAwaitable

        let
          isCompletedAwaitable :: Awaitable ()
          isCompletedAwaitable = awaitResourceManagerResult $ ResourceManagerResult resourceManagerKey cachedResultAwaitable

        alreadyCompleted <- isJust <$> peekAwaitable isCompletedAwaitable
        if alreadyCompleted
          then do
            completeDisposing
            pure DisposeResultDisposed
          else do
            -- Start thread to collect exceptions, await completion and run finalizers
            forkDisposeThread do
              -- Collect exceptions from directly attached disposables
              sequence_ reportExceptionActions
              -- Await completion attached resource managers
              await isCompletedAwaitable

              completeDisposing

      forkDisposeThread :: IO () -> IO DisposeResult
      forkDisposeThread action = do
        defaultResourceManagerDisposeResult self <$ forkIO do
          catchAll
            action
            \ex ->
              atomically $ throwToHandler $ toException $
                userError ("Dispose thread failed for ResourceManager: " <> displayException ex)

      takeDisposables :: STM [Disposable]
      takeDisposables = toList <$> takeTMVar disposablesVar

      beginDisposeEntry :: Disposable -> IO (IO (), (Awaitable [ResourceManagerResult]))
      beginDisposeEntry disposable =
        catchAll
          do
            result <- beginDispose disposable
            pure case result of
              DisposeResultDisposed -> (pure (), pure [])
              -- Moves error reporting from the awaitable to the finalizer thread
              DisposeResultAwait awaitable -> (processDisposeException awaitable, [] <$ awaitSuccessOrFailure awaitable)
              DisposeResultResourceManager resourceManagerResult -> (pure (), pure [resourceManagerResult])
          \ex -> do
            atomically $ throwToHandler $ toException $ DisposeException ex
            pure (pure (), pure [])

      processDisposeException :: Awaitable () -> IO ()
      processDisposeException awaitable =
        await awaitable
          `catchAll`
            \ex -> atomically $ throwToHandler $ toException $ DisposeException ex

      completeDisposing :: IO ()
      completeDisposing =
        atomically do
          writeTVar stateVar $ ResourceManagerDisposed
          defaultRunFinalizers finalizers

  isDisposed ResourceManagerCore{stateVar} =
    unsafeAwaitSTM do
      disposed <- stateIsDisposed <$> readTVar stateVar
      check disposed
    where
      stateIsDisposed :: ResourceManagerState -> Bool
      stateIsDisposed ResourceManagerDisposed = True
      stateIsDisposed _ = False

  registerFinalizer ResourceManagerCore{finalizers} = defaultRegisterFinalizer finalizers

defaultResourceManagerDisposeResult :: ResourceManagerCore -> DisposeResult
defaultResourceManagerDisposeResult ResourceManagerCore{resourceManagerKey, resultVar} =
  DisposeResultResourceManager $ ResourceManagerResult resourceManagerKey $ join $ toAwaitable resultVar

-- | Internal constructor. The resulting resource manager core is indirectly attached to it's parent by it's exception
-- handler.
newUnmanagedDefaultResourceManagerInternal :: (SomeException -> STM ()) -> STM ResourceManagerCore
newUnmanagedDefaultResourceManagerInternal throwToHandler = do
  resourceManagerKey <- newUniqueSTM
  stateVar <- newTVar ResourceManagerNormal
  disposablesVar <- newTMVar HM.empty
  lockVar <- newTVar 0
  finalizers <- newDisposableFinalizersSTM
  resultVar <- newAsyncVarSTM

  pure ResourceManagerCore {
    resourceManagerKey,
    throwToHandler,
    stateVar,
    disposablesVar,
    lockVar,
    finalizers,
    resultVar
  }

newResourceManager :: MonadResourceManager m => m ResourceManager
newResourceManager = do
  parent <- askResourceManager
  runInSTM $ newResourceManagerSTM parent

newResourceManagerSTM :: ResourceManager -> STM ResourceManager
newResourceManagerSTM parent = do
  -- Bind core exception handler to parent to tie exception handling to the parent
  resourceManager <- newUnmanagedDefaultResourceManagerInternal (throwToResourceManagerImpl parent)
  -- Attach disposable to parent to tie resource management to the parent
  attachDisposable parent resourceManager
  pure $ NormalResourceManager resourceManager parent


-- * Utilities

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: ResourceManager -> IO () -> STM Disposable
attachDisposeAction resourceManager action = do
  disposable <- newDisposable action
  attachDisposable resourceManager disposable
  pure disposable

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: ResourceManager -> IO () -> STM ()
attachDisposeAction_ resourceManager action = void $ attachDisposeAction resourceManager action


-- ** Link execution to resource manager

-- | A computation bound to a resource manager with 'linkThread' should be canceled.
data CancelLinkedExecution = CancelLinkedExecution Unique
  deriving anyclass Exception

instance Show CancelLinkedExecution where
  show _ = "CancelLinkedExecution"


data LinkState = LinkStateLinked ThreadId | LinkStateThrowing | LinkStateCompleted
  deriving stock Eq


-- | Links the execution of a computation to a resource manager.
--
-- The computation is executed on the current thread. When the resource manager is disposed before the computation
-- is completed, a `CancelLinkedExecution`-exception is thrown to the current thread.
linkExecution :: (MonadResourceManager m, MonadIO m, MonadMask m) => m a -> m (Maybe a)
linkExecution action = do
  key <- liftIO $ newUnique
  var <- liftIO $ newTVarIO =<< LinkStateLinked <$> myThreadId
  registerDisposeAction $ do
    atomically (swapTVar var LinkStateThrowing) >>= \case
      LinkStateLinked threadId -> throwTo threadId $ CancelLinkedExecution key
      LinkStateThrowing -> pure () -- Dispose called twice
      LinkStateCompleted -> pure () -- Thread has already left link

  catch
    do
      result <- action
      state <- liftIO $ atomically $ swapTVar var LinkStateCompleted
      when (state == LinkStateThrowing) $ sleepForever -- Wait for exception to arrive
      pure $ Just result

    \ex@(CancelLinkedExecution exceptionKey) ->
      if key == exceptionKey
        then return Nothing
        else throwM ex
