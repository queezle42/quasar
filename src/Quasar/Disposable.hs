module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  disposeIO,
  newDisposable,
  synchronousDisposable,
  noDisposable,
  alreadyDisposing,

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

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Data.Maybe (isJust)
import Data.Sequence
import Data.Sequence qualified as Seq
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
  toAwaitable :: FnDisposable -> Awaitable ()
  toAwaitable (FnDisposable var) =
    join $ simpleAwaitable do
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
    varContents <- simpleAwaitable $ tryReadTMVar var
    case varContents of
      -- If the var is empty the Entry has already been disposed
      Nothing -> pure ()
      Just (awaitable, _) -> awaitable

newEntry :: IsDisposable a => a -> IO ResourceManagerEntry
newEntry disposable = do
  traceIO "newEntry"
  awaitable <- cacheAwaitable (isDisposed disposable)
  traceIO "newEntry: cached"
  ResourceManagerEntry <$> newTMVarIO (awaitable, toDisposable disposable)

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


data ResourceManager = ResourceManager {
  disposingVar :: TVar Bool,
  disposedVar :: TVar Bool,
  exceptionVar :: TMVar SomeException,
  entriesVar :: TVar (Seq ResourceManagerEntry)
}

class HasResourceManager a where
  getResourceManager :: a -> ResourceManager

instance IsDisposable ResourceManager where
  dispose resourceManager = mask \unmask ->
    unmask dispose' `catchAll` \ex -> traceIO "ResourceManager.dispose: disposing failed" >> setException resourceManager ex >> throwIO ex
    where
      dispose' :: IO (Awaitable ())
      dispose' = do
        entries <- atomically do
          alreadyDisposing <- swapTVar (disposingVar resourceManager) True
          if not alreadyDisposing
            then readTVar (entriesVar resourceManager)
            else pure Empty

        mapM_ entryStartDispose entries
        traceIO "ResourceManager.dispose: dispose started, waiting for gc"
        pure $ isDisposed resourceManager

  isDisposed resourceManager =
    simpleAwaitable do
      (throwM =<< readTMVar (exceptionVar resourceManager))
        `orElse`
          ((\disposed -> unless disposed retry) =<< readTVar (disposedVar resourceManager))

withResourceManager :: (ResourceManager -> IO a) -> IO a
withResourceManager = bracket newResourceManager (awaitIO <=< dispose)

newResourceManager :: IO ResourceManager
newResourceManager = do
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
    unmask (collectGarbage resourceManager) `catchAll` \ex -> traceIO ("gc: failure: " <> displayException ex) >> setException resourceManager ex

  pure resourceManager


collectGarbage :: ResourceManager -> IO ()
collectGarbage resourceManager = go >> traceIO "gc: completed"
  where
    go :: IO ()
    go = do
      traceIO "gc: go"
      snapshot <- atomically $ readTVar entriesVar'

      let listChanged = simpleAwaitable do
            newLength <- Seq.length <$> readTVar entriesVar'
            when (newLength == Seq.length snapshot) retry

          isDisposing = simpleAwaitable do
            disposing <- readTVar (disposingVar resourceManager)
            unless disposing retry

      -- Wait for any entry to complete or until a new entry is added
      let awaitables = (toAwaitable <$> toList snapshot)
      awaitIO if Quasar.Prelude.null awaitables
        then awaitAny2 listChanged isDisposing
        else awaitAny (listChanged :| awaitables)

      traceIO "gc: change detected"

      -- Check entries for completion. Completion will be queried with `entryIsEmpty` during the next STM transaction.
      checkEntries =<< atomically (readTVar entriesVar')

      traceIO "gc: entries checked"

      join $ atomically $ do
        disposing <- readTVar (disposingVar resourceManager)

        -- Filter completed entries
        allEntries <- readTVar entriesVar'
        filteredEntries <- foldM (\acc entry -> entryIsEmpty entry >>= \empty -> pure if empty then acc else acc |> entry) Empty allEntries
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
  traceIO "attachDisposable called"
  entry <- newEntry disposable

  traceIO "attachDisposable: entry created"

  join $ atomically do
    mapM throwM =<< tryReadTMVar (exceptionVar resourceManager)

    disposed <- readTVar (disposedVar resourceManager)
    when disposed $ throwM (userError "Cannot attach a disposable to a disposed resource manager")

    modifyTVar (entriesVar resourceManager) (|> entry)

    disposing <- readTVar (disposingVar resourceManager)

    pure do
      -- IO that is run after the STM transaction is completed
      traceIO "attachDisposable: transacton complete"
      when disposing $ do
        traceIO "attachDisposable: dispose"
        void $ unmask (dispose disposable) `catchAll` \ex -> setException resourceManager ex >> throwIO ex
        traceIO "attachDisposable: disposed"

-- | Creates an `Disposable` that is bound to a ResourceManager. It will automatically be disposed when the resource manager is disposed.
attachDisposeAction :: MonadIO m => ResourceManager -> IO (Awaitable ()) -> m Disposable
attachDisposeAction resourceManager action = do
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
    Just (Left ex) -> throwIO ex
    Just (Right ()) -> pure ()
    Nothing -> attachDisposable resourceManager disposable
