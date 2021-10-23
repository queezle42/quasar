module Quasar.ResourceManager (
  -- * MonadResourceManager
  MonadResourceManager(..),
  FailedToRegisterResource,
  registerNewResource,
  registerDisposable,
  registerDisposeAction,
  withSubResourceManagerM,
  onResourceManager,
  captureDisposable,
  captureDisposable_,

  -- ** Top level initialization
  withRootResourceManager,

  -- ** ResourceManager
  IsResourceManager(..),
  ResourceManager,
  newResourceManager,
  attachDisposeAction,
  attachDisposeAction_,

  -- ** Linking computations to a resource manager
  linkExecution,
  CancelLinkedExecution,

  -- * Reexports
  CombinedException,
  combinedExceptions,
) where


import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.List.NonEmpty (NonEmpty(..), (<|), nonEmpty)
import Data.Sequence (Seq(..), (|>))
import Data.Sequence qualified as Seq
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude
import Quasar.Utils.Concurrent
import Quasar.Utils.Exceptions


data DisposeException = DisposeException SomeException
  deriving stock Show
  deriving anyclass Exception

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

class IsDisposable a => IsResourceManager a where
  toResourceManager :: a -> ResourceManager
  toResourceManager = ResourceManager

  -- | Attaches an `Disposable` to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
  --
  -- May throw an `FailedToRegisterResource` if the resource manager is disposing/disposed.
  attachDisposable :: (IsDisposable b, MonadIO m) => a -> b -> m ()
  attachDisposable self = attachDisposable (toResourceManager self)

  lockResourceManager :: (IsDisposable b, MonadIO m, MonadMask m) => a -> m b -> m b
  lockResourceManager self = lockResourceManager (toResourceManager self)

  -- | Forward an exception that happened asynchronously.
  throwToResourceManager :: Exception e => a -> e -> IO ()
  throwToResourceManager = throwToResourceManager . toResourceManager

  {-# MINIMAL toResourceManager | (attachDisposable, lockResourceManager, throwToResourceManager) #-}


data ResourceManager = forall a. IsResourceManager a => ResourceManager a
instance IsResourceManager ResourceManager where
  toResourceManager = id
  attachDisposable (ResourceManager x) = attachDisposable x
  lockResourceManager (ResourceManager x) = lockResourceManager x
  throwToResourceManager (ResourceManager x) = throwToResourceManager x
instance IsDisposable ResourceManager where
  toDisposable (ResourceManager x) = toDisposable x

class (MonadAwait m, MonadMask m, MonadIO m, MonadFix m) => MonadResourceManager m where
  -- | Get the underlying resource manager.
  askResourceManager :: m ResourceManager

  -- | Replace the resource manager for a computation.
  localResourceManager :: IsResourceManager a => a -> m r -> m r


-- | Register a `Disposable` to the resource manager.
--
-- May throw an `FailedToRegisterResource` if the resource manager is disposing/disposed.
registerDisposable :: (IsDisposable a, MonadResourceManager m) => a -> m ()
registerDisposable disposable = do
  resourceManager <- askResourceManager
  attachDisposable resourceManager disposable


registerDisposeAction :: MonadResourceManager m => IO () -> m ()
registerDisposeAction disposeAction = mask_ $ registerDisposable =<< newDisposable disposeAction

registerNewResource :: (IsDisposable a, MonadResourceManager m) => m a -> m a
registerNewResource action = mask_ do
  resourceManager <- askResourceManager
  lockResourceManager resourceManager do
    resource <- action
    attachDisposable resourceManager resource
    pure resource


-- TODO rename to withResourceScope, subResourceManager or withResourceManager?
withSubResourceManagerM :: MonadResourceManager m => m a -> m a
withSubResourceManagerM action =
  bracket newResourceManager dispose \scope -> localResourceManager scope action


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



-- * Resource manager implementations

-- ** Root resource manager

data RootResourceManager
  = RootResourceManager DefaultResourceManager (TVar Bool) (TMVar (Seq SomeException)) (AsyncVar [SomeException])

instance IsResourceManager RootResourceManager where
  attachDisposable (RootResourceManager internal _ _ _) = attachDisposable internal
  lockResourceManager (RootResourceManager internal _ _ _) = lockResourceManager internal
  throwToResourceManager (RootResourceManager _ _ exceptionsVar _) ex = do
    -- TODO only log exceptions after a timeout
    traceIO $ "Exception thrown to root resource manager: " <> displayException ex
    liftIO $ join $ atomically do
      tryTakeTMVar exceptionsVar >>= \case
        Just exceptions -> do
          putTMVar exceptionsVar (exceptions |> toException ex)
          pure $ pure @IO ()
        Nothing -> do
          pure $ fail @IO "Could not throw to resource manager: RootResourceManager is already disposed"


instance IsDisposable RootResourceManager where
  beginDispose (RootResourceManager internal disposingVar _ _) = do
    defaultResourceManagerDisposeResult internal <$ atomically do
      disposing <- readTVar disposingVar
      unless disposing $ writeTVar disposingVar True

  isDisposed (RootResourceManager internal _ _ _) = isDisposed internal

  registerFinalizer (RootResourceManager internal _ _ _) = registerFinalizer internal

newUnmanagedRootResourceManagerInternal :: MonadIO m => m RootResourceManager
newUnmanagedRootResourceManagerInternal = liftIO do
  disposingVar <- newTVarIO False
  exceptionsVar <- newTMVarIO Empty
  finalExceptionsVar <- newAsyncVar
  mfix \root -> do
    unmanagedFork_ (disposeThread root)
    internal <- newUnmanagedDefaultResourceManagerInternal (toResourceManager root)
    pure $ RootResourceManager internal disposingVar exceptionsVar finalExceptionsVar

  where
    disposeThread :: RootResourceManager -> IO ()
    disposeThread (RootResourceManager internal disposingVar exceptionsVar finalExceptionsVar) =
      handleAll
        do \ex -> fail $ "RootResourceManager thread failed unexpectedly: " <> displayException ex
        do
          -- Wait until disposing
          atomically do
            disposing <- readTVar disposingVar
            hasExceptions <- (> 0) . Seq.length <$> readTMVar exceptionsVar
            check $ disposing || hasExceptions

          -- TODO start the thread that reports exceptions (or a potential hang) after a timeout

          dispose internal

          atomically do
            -- The var is set to `Nothing` to signal that no more exceptions can be received
            exceptions <- takeTMVar exceptionsVar

            putAsyncVarSTM_ finalExceptionsVar $ toList exceptions


withRootResourceManager :: (MonadAwait m, MonadMask m, MonadIO m) => ReaderT ResourceManager IO a -> m a
withRootResourceManager action = uninterruptibleMask \unmask -> do
  resourceManager@(RootResourceManager _ _ _ finalExceptionsVar) <- newUnmanagedRootResourceManagerInternal

  result <- try $ unmask $ onResourceManager resourceManager action

  disposeEventually_ resourceManager
  exceptions <- await finalExceptionsVar

  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right result' -> maybe (pure result') (throwM . CombinedException) $ nonEmpty exceptions


-- ** Default resource manager

data DefaultResourceManager = DefaultResourceManager {
  resourceManagerKey :: Unique,
  throwToHandler :: SomeException -> IO (),
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

instance IsResourceManager DefaultResourceManager where
  throwToResourceManager DefaultResourceManager{throwToHandler} = throwToHandler . toException

  attachDisposable DefaultResourceManager{stateVar, disposablesVar} disposable = liftIO $ mask_ do
    key <- newUnique
    join $ atomically do
      state <- readTVar stateVar
      case state of
        ResourceManagerNormal -> do
          disposables <- takeTMVar disposablesVar
          putTMVar disposablesVar (HM.insert key (toDisposable disposable) disposables)
          registerFinalizer disposable (finalizer key)
          pure $ pure @IO ()
        _ -> pure $ throwM @IO FailedToRegisterResource
    where
      finalizer :: Unique -> STM ()
      finalizer key =
        tryTakeTMVar disposablesVar >>= \case
          Just disposables ->
            putTMVar disposablesVar $ HM.delete key disposables
          Nothing -> pure ()

  lockResourceManager DefaultResourceManager{stateVar, lockVar} =
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

instance IsDisposable DefaultResourceManager where
  beginDispose self@DefaultResourceManager{resourceManagerKey, stateVar, disposablesVar, lockVar, resultVar, finalizers} = liftIO do
    uninterruptibleMask_ do
      join $ atomically do
        state <- readTVar stateVar
        case state of
          ResourceManagerNormal -> do
            writeTVar stateVar $ ResourceManagerDisposing
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
        cachedResultAwaitable <- cacheAwaitable $ mconcat resultAwaitables
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
            \ex -> throwToResourceManager self (userError ("Dispose thread failed for DefaultResourceManager: " <> displayException ex))

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
            throwToResourceManager self $ DisposeException ex
            pure (pure (), pure [])

      processDisposeException :: Awaitable () -> IO ()
      processDisposeException awaitable =
        await awaitable
          `catchAll`
            \ex -> throwToResourceManager self $ DisposeException ex

      completeDisposing :: IO ()
      completeDisposing =
        atomically do
          writeTVar stateVar $ ResourceManagerDisposed
          defaultRunFinalizers finalizers

  isDisposed DefaultResourceManager{stateVar} =
    unsafeAwaitSTM do
      disposed <- stateIsDisposed <$> readTVar stateVar
      check disposed
    where
      stateIsDisposed :: ResourceManagerState -> Bool
      stateIsDisposed ResourceManagerDisposed = True
      stateIsDisposed _ = False

  registerFinalizer DefaultResourceManager{finalizers} = defaultRegisterFinalizer finalizers

defaultResourceManagerDisposeResult :: DefaultResourceManager -> DisposeResult
defaultResourceManagerDisposeResult DefaultResourceManager{resourceManagerKey, resultVar} =
  DisposeResultResourceManager $ ResourceManagerResult resourceManagerKey $ join $ toAwaitable resultVar

newUnmanagedDefaultResourceManager :: MonadIO m => ResourceManager -> m ResourceManager
newUnmanagedDefaultResourceManager parentResourceManager = liftIO do
  toResourceManager <$> newUnmanagedDefaultResourceManagerInternal parentResourceManager

newUnmanagedDefaultResourceManagerInternal :: MonadIO m => ResourceManager -> m DefaultResourceManager
newUnmanagedDefaultResourceManagerInternal parentResourceManager = liftIO do
  resourceManagerKey <- newUnique
  stateVar <- newTVarIO ResourceManagerNormal
  disposablesVar <- newTMVarIO HM.empty
  lockVar <- newTVarIO 0
  finalizers <- newDisposableFinalizers
  resultVar <- newAsyncVar

  pure DefaultResourceManager {
    resourceManagerKey,
    throwToHandler = throwToResourceManager parentResourceManager,
    stateVar,
    disposablesVar,
    lockVar,
    finalizers,
    resultVar
  }

newResourceManager :: MonadResourceManager m => m ResourceManager
newResourceManager = mask_ do
  parent <- askResourceManager
  resourceManager <- newUnmanagedDefaultResourceManager parent
  registerDisposable resourceManager
  pure resourceManager


-- * Utilities

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO () -> m Disposable
attachDisposeAction resourceManager action = liftIO $ mask_ $ do
  disposable <- newDisposable action
  attachDisposable resourceManager disposable
  pure disposable

-- | Attaches a dispose action to a ResourceManager. It will automatically be run when the resource manager is disposed.
attachDisposeAction_ :: MonadIO m => ResourceManager -> IO () -> m ()
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
linkExecution :: MonadResourceManager m => m a -> m (Maybe a)
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

