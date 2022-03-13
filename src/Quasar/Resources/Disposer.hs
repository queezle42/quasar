{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Disposer (
  Resource(..),
  Disposer,
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  isDisposing,
  isDisposed,
  newUnmanagedPrimitiveDisposer,

  -- * Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
) where


import Control.Monad (foldM)
import Control.Monad.Catch
import Data.Either (isRight)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO
import Quasar.Utils.TOnce


class Resource a where
  getDisposer :: a -> Disposer


type DisposerState = TOnce DisposeFn (Future ())

data Disposer
  = FnDisposer Unique TIOWorker ExceptionSink DisposerState Finalizers
  | ResourceManagerDisposer ResourceManager

instance Resource Disposer where
  getDisposer = id

type DisposeFn = ShortIO (Future ())


newUnmanagedPrimitiveDisposer :: ShortIO (Future ()) -> TIOWorker -> ExceptionSink -> STM Disposer
newUnmanagedPrimitiveDisposer fn worker exChan = do
  key <- newUniqueSTM
  FnDisposer key worker exChan <$> newTOnce fn <*> newFinalizers


dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventuallySTM resource)

disposeEventuallySTM :: Resource r => r -> STM (Future ())
disposeEventuallySTM resource =
  case getDisposer resource of
    FnDisposer _ worker exChan state finalizers -> do
      beginDisposeFnDisposer worker exChan state finalizers
    ResourceManagerDisposer resourceManager ->
      beginDisposeResourceManager resourceManager

disposeEventuallySTM_ :: Resource r => r -> STM ()
disposeEventuallySTM_ resource = void $ disposeEventuallySTM resource


isDisposed :: Resource a => a -> Future ()
isDisposed resource =
  case getDisposer resource of
    FnDisposer _ _ _ state _ -> join (toFuture state)
    ResourceManagerDisposer resourceManager -> resourceManagerIsDisposed resourceManager

isDisposing :: Resource a => a -> Future ()
isDisposing resource =
  case getDisposer resource of
    FnDisposer _ _ _ state _ -> unsafeAwaitSTM (check . isRight =<< readTOnceState state)
    ResourceManagerDisposer resourceManager -> resourceManagerIsDisposing resourceManager



beginDisposeFnDisposer :: TIOWorker -> ExceptionSink -> DisposerState -> Finalizers -> STM (Future ())
beginDisposeFnDisposer worker exChan disposeState finalizers =
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFn -> STM (Future ())
    startDisposeFn disposeFn = do
      awaitableVar <- newPromiseSTM
      startShortIOSTM_ (runDisposeFn awaitableVar disposeFn) worker exChan
      pure $ join (toFuture awaitableVar)

    runDisposeFn :: Promise (Future ()) -> DisposeFn -> ShortIO ()
    runDisposeFn awaitableVar disposeFn = mask_ $ handleAll exceptionHandler do
      awaitable <- disposeFn
      fulfillPromiseShortIO awaitableVar awaitable
      runFinalizersAfter finalizers awaitable
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO awaitableVar (pure ())
          runFinalizersShortIO finalizers
          throwM $ DisposeException ex

disposerKey :: Disposer -> Unique
disposerKey (FnDisposer key _ _ _ _) = key
disposerKey (ResourceManagerDisposer resourceManager) = resourceManagerKey resourceManager


disposerFinalizers :: Disposer -> Finalizers
disposerFinalizers (FnDisposer _ _ _ _ finalizers) = finalizers
disposerFinalizers (ResourceManagerDisposer rm) = resourceManagerFinalizers rm



data DisposeResult
  = DisposeResultAwait (Future ())
  | DisposeResultDependencies DisposeDependencies

data DisposeDependencies = DisposeDependencies Unique (Future [DisposeDependencies])


-- * Resource manager

data ResourceManager = ResourceManager {
  resourceManagerKey :: Unique,
  resourceManagerState :: TVar ResourceManagerState,
  resourceManagerFinalizers :: Finalizers
}

data ResourceManagerState
  = ResourceManagerNormal (TVar (HashMap Unique Disposer)) TIOWorker ExceptionSink
  | ResourceManagerDisposing (Future [DisposeDependencies])
  | ResourceManagerDisposed

instance Resource ResourceManager where
  getDisposer = ResourceManagerDisposer


newUnmanagedResourceManagerSTM :: TIOWorker -> ExceptionSink -> STM ResourceManager
newUnmanagedResourceManagerSTM worker exChan = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources worker exChan)
  resourceManagerFinalizers <- newFinalizers
  pure ResourceManager {
    resourceManagerKey,
    resourceManagerState,
    resourceManagerFinalizers
  }


attachResource :: Resource a => ResourceManager -> a -> STM ()
attachResource resourceManager resource =
  attachDisposer resourceManager (getDisposer resource)

attachDisposer :: ResourceManager -> Disposer -> STM ()
attachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ _ -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        -- Returns false if the disposer is already finalized
        attachedFinalizer <- registerFinalizer (disposerFinalizers disposer) finalizer
        when attachedFinalizer $ modifyTVar attachedResources (HM.insert key disposer)
    _ -> undefined -- failed to attach resource; arguably this should just dispose?
  where
    key :: Unique
    key = disposerKey disposer
    finalizer :: STM ()
    finalizer = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources _ _ -> modifyTVar attachedResources (HM.delete key)
      -- No finalization required in other states, since all resources are disposed soon
      -- (and awaiting each resource is cheaper than modifying a HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManager :: ResourceManager -> STM (Future ())
beginDisposeResourceManager rm = do
  void $ beginDisposeResourceManagerInternal rm
  pure $ resourceManagerIsDisposed rm

beginDisposeResourceManagerInternal :: ResourceManager -> STM DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources worker exChan -> do
      dependenciesVar <- newPromiseSTM
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toFuture dependenciesVar))
      attachedDisposers <- HM.elems <$> readTVar attachedResources
      startShortIOSTM_ (void $ forkIOShortIO (disposeThread dependenciesVar attachedDisposers)) worker exChan
      pure $ DisposeDependencies rmKey (toFuture dependenciesVar)
    ResourceManagerDisposing deps -> pure $ DisposeDependencies rmKey deps
    ResourceManagerDisposed -> pure $ DisposeDependencies rmKey mempty
  where
    disposeThread :: Promise [DisposeDependencies] -> [Disposer] -> IO ()
    disposeThread dependenciesVar attachedDisposers = do
      -- Begin to dispose all attached resources
      results <- mapM (atomically . resourceManagerBeginDispose) attachedDisposers
      -- Await direct resource awaitables and collect indirect dependencies
      dependencies <- await (collectDependencies results)
      -- Publish "direct dependencies complete"-status
      fulfillPromise dependenciesVar dependencies
      -- Await indirect dependencies
      awaitDisposeDependencies $ DisposeDependencies rmKey (pure dependencies)
      -- Set state to disposed and run finalizers
      atomically do
        writeTVar (resourceManagerState rm) ResourceManagerDisposed
        runFinalizers (resourceManagerFinalizers rm)

    rmKey :: Unique
    rmKey = resourceManagerKey rm

    resourceManagerBeginDispose :: Disposer -> STM DisposeResult
    resourceManagerBeginDispose (FnDisposer _ worker exChan state finalizers) =
      DisposeResultAwait <$> beginDisposeFnDisposer worker exChan state finalizers
    resourceManagerBeginDispose (ResourceManagerDisposer resourceManager) =
      DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager

    collectDependencies :: [DisposeResult] -> Future [DisposeDependencies]
    collectDependencies (DisposeResultAwait awaitable : xs) = awaitable >> collectDependencies xs
    collectDependencies (DisposeResultDependencies deps : xs) = (deps : ) <$> collectDependencies xs
    collectDependencies [] = pure []

    awaitDisposeDependencies :: DisposeDependencies -> IO ()
    awaitDisposeDependencies = void . go mempty
      where
        go :: HashSet Unique -> DisposeDependencies -> IO (HashSet Unique)
        go keys (DisposeDependencies key deps)
          | HashSet.member key keys = pure keys -- loop detection: dependencies were already handled
          | otherwise = do
              dependencies <- await deps
              foldM go (HashSet.insert key keys) dependencies


resourceManagerIsDisposed :: ResourceManager -> Future ()
resourceManagerIsDisposed rm = unsafeAwaitSTM $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerDisposed -> pure ()
    _ -> retry

resourceManagerIsDisposing :: ResourceManager -> Future ()
resourceManagerIsDisposing rm = unsafeAwaitSTM $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal {} -> retry
    _ -> pure ()



-- * Implementation internals

newtype Finalizers = Finalizers (TMVar [STM ()])

newFinalizers :: STM Finalizers
newFinalizers = do
  Finalizers <$> newTMVar []

registerFinalizer :: Finalizers -> STM () -> STM Bool
registerFinalizer (Finalizers finalizerVar) finalizer =
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> do
      putTMVar finalizerVar (finalizer : finalizers)
      pure True
    Nothing -> pure False

runFinalizers :: Finalizers -> STM ()
runFinalizers (Finalizers finalizerVar) = do
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> sequence_ finalizers
    Nothing -> throwM $ userError "runFinalizers was called multiple times (it must only be run once)"

runFinalizersShortIO :: Finalizers -> ShortIO ()
runFinalizersShortIO finalizers = unsafeShortIO $ atomically $ runFinalizers finalizers

runFinalizersAfter :: Finalizers -> Future () -> ShortIO ()
runFinalizersAfter finalizers awaitable = do
  -- Peek awaitable to ensure trivial disposables always run without forking
  isCompleted <- isJust <$> peekFutureShortIO awaitable
  if isCompleted
    then
      runFinalizersShortIO finalizers
    else
      void $ forkIOShortIO do
        await awaitable
        atomically $ runFinalizers finalizers
