{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Disposer (
  Resource(..),
  Disposer,
  dispose,
  disposeEventually,
  disposeEventually_,
  newUnmanagedIODisposer,
  newUnmanagedSTMDisposer,
  trivialDisposer,

  TDisposer,
  disposeTDisposer,

  TSimpleDisposer,
  newUnmanagedTSimpleDisposer,
  disposeTSimpleDisposer,

  -- * Resource manager
  ResourceManager,
  newUnmanagedResourceManagerSTM,
  attachResource,
  tryAttachResource,
) where


import Control.Monad (foldM)
import Control.Monad.Catch
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO
import Quasar.Utils.TOnce


class Resource a where
  toDisposer :: a -> Disposer

  isDisposed :: a -> Future ()
  isDisposed r = isDisposed (toDisposer r)

  isDisposing :: a -> Future ()
  isDisposing r = isDisposing (toDisposer r)



newtype Disposer = Disposer [DisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Resource Disposer where
  toDisposer = id
  isDisposed (Disposer ds) = foldMap isDisposed ds
  isDisposing (Disposer ds) = awaitAny $ isDisposing <$> ds

newtype TDisposer = TDisposer [TDisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Resource TDisposer where
  toDisposer (TDisposer ds) = toDisposer ds


type DisposerState = TOnce DisposeFnIO (Future ())

data DisposerElement
  = IODisposer Unique TIOWorker ExceptionSink DisposerState Finalizers
  | STMDisposer TDisposerElement
  | STMSimpleDisposer TSimpleDisposerElement
  | ResourceManagerDisposer ResourceManager

instance Resource DisposerElement where
  toDisposer disposer = Disposer [disposer]

  isDisposed (IODisposer _ _ _ state _) = join (toFuture state)
  isDisposed (STMDisposer tdisposer) = isDisposed tdisposer
  isDisposed (STMSimpleDisposer tdisposer) = isDisposed tdisposer
  isDisposed (ResourceManagerDisposer resourceManager) = resourceManagerIsDisposed resourceManager

  isDisposing (IODisposer _ _ _ state _) = void (toFuture state)
  isDisposing (STMDisposer tdisposer) = isDisposing tdisposer
  isDisposing (STMSimpleDisposer tdisposer) = isDisposing tdisposer
  isDisposing (ResourceManagerDisposer resourceManager) = resourceManagerIsDisposing resourceManager


type DisposeFn = ShortIO (Future ())
type DisposeFnIO = IO ()


type STMDisposerState = TOnce (STM ()) (Future ())

data TDisposerElement = TDisposerElement Unique TIOWorker ExceptionSink STMDisposerState Finalizers

instance Resource TDisposerElement where
  toDisposer disposer = Disposer [STMDisposer disposer]
  isDisposed (TDisposerElement _ _ _ state _) = join (toFuture state)
  isDisposing (TDisposerElement _ _ _ state _) = void (toFuture state)

instance Resource [TDisposerElement] where
  toDisposer tds = Disposer (STMDisposer <$> tds)
  isDisposed tds = isDisposed (toDisposer tds)
  isDisposing tds = isDisposing (toDisposer tds)

newUnmanagedSTMDisposer :: MonadSTMc '[] m => STM () -> TIOWorker -> ExceptionSink -> m TDisposer
newUnmanagedSTMDisposer fn worker sink = do
  key <- newUniqueSTM
  element <-  TDisposerElement key worker sink <$> newTOnce fn <*> newFinalizers
  pure $ TDisposer [element]

disposeTDisposer :: MonadSTM m => TDisposer -> m ()
disposeTDisposer (TDisposer elements) = liftSTM $ mapM_ go elements
  where
    go (TDisposerElement _ _ sink state finalizers) = do
      future <- mapFinalizeTOnce state startDisposeFn
      -- Elements can also be disposed by a resource manager (on a dedicated thread).
      -- In that case that thread has to be awaited (otherwise this is a no-op).
      awaitSTM future
      where
        startDisposeFn :: STM () -> STM (Future ())
        startDisposeFn disposeFn = do
          disposeFn `catchAll` throwToExceptionSink sink
          liftSTMc $ runFinalizers finalizers
          pure $ pure ()

beginDisposeSTMDisposer :: forall m. MonadSTMc '[] m => TDisposerElement -> m (Future ())
beginDisposeSTMDisposer (TDisposerElement _ worker sink state finalizers) = liftSTMc do
  mapFinalizeTOnce state startDisposeFn
  where
    startDisposeFn :: STM () -> STMc '[] (Future ())
    startDisposeFn fn = do
      promise <- newPromiseSTM
      startShortIOSTM_ (runDisposeFn promise disposeFn) worker sink
      pure $ join (toFuture promise)
      where
        disposeFn :: ShortIO (Future ())
        disposeFn = unsafeShortIO $ atomically $
          -- Spawn a thread only if the transaction retries
          (pure <$> fn) `orElse` (void . toFuture <$> forkAsyncSTM (atomically fn) worker sink)

    runDisposeFn :: Promise (Future ()) -> DisposeFn -> ShortIO ()
    runDisposeFn promise disposeFn = mask_ $ handleAll exceptionHandler do
      future <- disposeFn
      fulfillPromiseShortIO promise future
      runFinalizersAfterShortIO finalizers future
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO promise (pure ())
          runFinalizersShortIO finalizers
          throwM $ DisposeException ex


type STMSimpleDisposerState = TOnce (STMc '[] ()) ()

data TSimpleDisposerElement = TSimpleDisposerElement Unique STMSimpleDisposerState Finalizers

newtype TSimpleDisposer = TSimpleDisposer [TSimpleDisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Resource TSimpleDisposer where
  toDisposer (TSimpleDisposer ds) = toDisposer ds

instance Resource TSimpleDisposerElement where
  toDisposer disposer = Disposer [STMSimpleDisposer disposer]
  isDisposed (TSimpleDisposerElement _ state _) = toFuture state
  isDisposing = isDisposed

instance Resource [TSimpleDisposerElement] where
  toDisposer tds = Disposer (STMSimpleDisposer <$> tds)
  isDisposed tds = isDisposed (toDisposer tds)
  isDisposing tds = isDisposing (toDisposer tds)

newUnmanagedTSimpleDisposer :: MonadSTMc '[] m => STMc '[] () -> m TSimpleDisposer
newUnmanagedTSimpleDisposer fn = do
  key <- newUniqueSTM
  element <-  TSimpleDisposerElement key <$> newTOnce fn <*> newFinalizers
  pure $ TSimpleDisposer [element]

disposeTSimpleDisposer :: MonadSTMc '[] m => TSimpleDisposer -> m ()
disposeTSimpleDisposer (TSimpleDisposer elements) = liftSTMc do
  mapM_ disposeTSimpleDisposerElement elements

disposeTSimpleDisposerElement :: TSimpleDisposerElement -> STMc '[] ()
disposeTSimpleDisposerElement (TSimpleDisposerElement _ state finalizers) =
  mapFinalizeTOnce state runDisposeFn
  where
    runDisposeFn :: STMc '[] () -> STMc '[] ()
    runDisposeFn disposeFn = do
      disposeFn
      runFinalizers finalizers


-- | A trivial disposer that does not perform any action when disposed.
trivialDisposer :: Disposer
trivialDisposer = mempty

newUnmanagedIODisposer :: MonadSTMc '[] m => IO () -> TIOWorker -> ExceptionSink -> m Disposer
newUnmanagedIODisposer fn worker exChan = toDisposer <$> do
  key <- newUniqueSTM
  state <- newTOnce fn
  finalizers <- newFinalizers
  pure $ IODisposer key worker exChan state finalizers


dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventually resource)

disposeEventually :: (Resource a, MonadSTMc '[] m) => a -> m (Future ())
disposeEventually (toDisposer -> Disposer ds) = liftSTMc do
  mconcat <$> mapM f ds
  where
    f :: DisposerElement -> STMc '[] (Future ())
    f (IODisposer _ worker exChan state finalizers) =
      beginDisposeIODisposer worker exChan state finalizers
    f (STMDisposer disposer) =
      beginDisposeSTMDisposer disposer
    f (STMSimpleDisposer disposer) =
      pure () <$ disposeTSimpleDisposerElement disposer
    f (ResourceManagerDisposer resourceManager) =
      beginDisposeResourceManager resourceManager

disposeEventually_ :: (Resource a, MonadSTMc '[] m) => a -> m ()
disposeEventually_ resource = void $ disposeEventually resource




beginDisposeIODisposer :: MonadSTMc '[] m => TIOWorker -> ExceptionSink -> DisposerState -> Finalizers -> m (Future ())
beginDisposeIODisposer worker exChan disposeState finalizers = liftSTMc do
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFnIO -> STMc '[] (Future ())
    startDisposeFn disposeFn = do
      promise <- newPromiseSTM
      startShortIOSTM_ (runDisposeFn promise disposeFn) worker exChan
      pure $ join (toFuture promise)

    runDisposeFn :: Promise (Future ()) -> DisposeFnIO -> ShortIO ()
    runDisposeFn promise disposeFn = mask_ $ handleAll exceptionHandler do
      futureE <- unsafeShortIO $ forkFuture disposeFn exChan
      -- Error is redirected to `exceptionHandler`, so the result can be safely ignored
      let future = void (toFuture futureE)
      fulfillPromiseShortIO promise future
      runFinalizersAfterShortIO finalizers future
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO promise (pure ())
          runFinalizersShortIO finalizers
          throwM $ DisposeException ex

disposerKey :: DisposerElement -> Unique
disposerKey (IODisposer key _ _ _ _) = key
disposerKey (STMDisposer (TDisposerElement key _ _ _ _)) = key
disposerKey (STMSimpleDisposer (TSimpleDisposerElement key _ _)) = key
disposerKey (ResourceManagerDisposer resourceManager) = resourceManagerKey resourceManager


disposerFinalizers :: DisposerElement -> Finalizers
disposerFinalizers (IODisposer _ _ _ _ finalizers) = finalizers
disposerFinalizers (STMDisposer (TDisposerElement _ _ _ _ finalizers)) = finalizers
disposerFinalizers (STMSimpleDisposer (TSimpleDisposerElement _ _ finalizers)) = finalizers
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
  = ResourceManagerNormal (TVar (HashMap Unique DisposerElement)) TIOWorker ExceptionSink
  | ResourceManagerDisposing (Future [DisposeDependencies])
  | ResourceManagerDisposed

instance Resource ResourceManager where
  toDisposer rm = Disposer [ResourceManagerDisposer rm]
  isDisposed = resourceManagerIsDisposed
  isDisposing = resourceManagerIsDisposing


newUnmanagedResourceManagerSTM :: MonadSTMc '[] m => TIOWorker -> ExceptionSink -> m ResourceManager
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


attachResource :: (MonadSTMc '[Throw FailedToAttachResource] m, Resource a) => ResourceManager -> a -> m ()
attachResource resourceManager disposer = liftSTMc @'[Throw FailedToAttachResource] do
  either throwC pure =<< tryAttachResource resourceManager disposer

tryAttachResource :: (MonadSTMc '[] m, Resource a) => ResourceManager -> a -> m (Either FailedToAttachResource ())
tryAttachResource resourceManager (toDisposer -> Disposer ds) = liftSTMc do
  sequence_ <$> mapM (tryAttachDisposer resourceManager) ds

tryAttachDisposer :: ResourceManager -> DisposerElement -> STMc '[] (Either FailedToAttachResource ())
tryAttachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ _ -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        -- Returns false if the disposer is already finalized
        attachedFinalizer <- registerFinalizer (disposerFinalizers disposer) finalizer
        when attachedFinalizer $ modifyTVar attachedResources (HM.insert key disposer)
      pure $ Right ()
    _ -> pure $ Left FailedToAttachResource
  where
    key :: Unique
    key = disposerKey disposer
    finalizer :: STMc '[] ()
    finalizer = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources _ _ -> modifyTVar attachedResources (HM.delete key)
      -- No finalization required in other states, since all resources are disposed soon
      -- (and awaiting each resource is cheaper than modifying a HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManager :: ResourceManager -> STMc '[] (Future ())
beginDisposeResourceManager rm = do
  void $ beginDisposeResourceManagerInternal rm
  pure $ resourceManagerIsDisposed rm

beginDisposeResourceManagerInternal :: ResourceManager -> STMc '[] DisposeDependencies
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
    disposeThread :: Promise [DisposeDependencies] -> [DisposerElement] -> IO ()
    disposeThread dependenciesVar attachedDisposers = do
      -- Begin to dispose all attached resources
      results <- mapM (atomicallyC . liftSTMc . resourceManagerBeginDispose) attachedDisposers
      -- Await direct resource awaitables and collect indirect dependencies
      dependencies <- await (collectDependencies results)
      -- Publish "direct dependencies complete"-status
      fulfillPromise dependenciesVar dependencies
      -- Await indirect dependencies
      awaitDisposeDependencies $ DisposeDependencies rmKey (pure dependencies)
      -- Set state to disposed and run finalizers
      atomicallyC $ liftSTMc do
        writeTVar (resourceManagerState rm) ResourceManagerDisposed
        runFinalizers (resourceManagerFinalizers rm)

    rmKey :: Unique
    rmKey = resourceManagerKey rm

    resourceManagerBeginDispose :: DisposerElement -> STMc '[] DisposeResult
    resourceManagerBeginDispose (IODisposer _ worker exChan state finalizers) =
      DisposeResultAwait <$> beginDisposeIODisposer worker exChan state finalizers
    resourceManagerBeginDispose (STMDisposer disposer) =
      DisposeResultAwait <$> beginDisposeSTMDisposer disposer
    resourceManagerBeginDispose (STMSimpleDisposer disposer) =
      DisposeResultAwait (pure ()) <$ disposeTSimpleDisposerElement disposer
    resourceManagerBeginDispose (ResourceManagerDisposer resourceManager) =
      DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager

    collectDependencies :: [DisposeResult] -> Future [DisposeDependencies]
    collectDependencies (DisposeResultAwait future : xs) = future >> collectDependencies xs
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
resourceManagerIsDisposed rm = unsafeAwaitSTMc $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerDisposed -> pure ()
    _ -> retry

resourceManagerIsDisposing :: ResourceManager -> Future ()
resourceManagerIsDisposing rm = unsafeAwaitSTMc $
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal {} -> retry
    _ -> pure ()


-- * Implementation internals

newtype Finalizers = Finalizers (TVar (Maybe [STMc '[] ()]))

newFinalizers :: MonadSTMc '[] m => m Finalizers
newFinalizers = Finalizers <$> newTVar (Just [])

registerFinalizer :: MonadSTMc '[] m => Finalizers -> STMc '[] () -> m Bool
registerFinalizer (Finalizers finalizerVar) finalizer =
  readTVar finalizerVar >>= \case
    Just finalizers -> do
      writeTVar finalizerVar (Just (finalizer : finalizers))
      pure True
    Nothing -> pure False

runFinalizers :: Finalizers -> STMc '[] ()
runFinalizers (Finalizers finalizerVar) = do
  readTVar finalizerVar >>= \case
    Just finalizers -> do
      liftSTMc $ sequence_ finalizers
      writeTVar finalizerVar Nothing
    Nothing -> traceM "runFinalizers was called multiple times (it must only be run once)"

runFinalizersShortIO :: Finalizers -> ShortIO ()
runFinalizersShortIO finalizers = unsafeShortIO $ atomicallyC $ liftSTMc $ runFinalizers finalizers

runFinalizersAfterShortIO :: Finalizers -> Future () -> ShortIO ()
runFinalizersAfterShortIO finalizers future = do
  -- Peek future to ensure trivial disposers always run without forking
  isCompleted <- isJust <$> peekFutureShortIO future
  if isCompleted
    then
      runFinalizersShortIO finalizers
    else
      void $ forkIOShortIO do
        await future
        atomicallyC $ liftSTMc $ runFinalizers finalizers


runFinalizersAfter :: TIOWorker -> Finalizers -> Future () -> STMc '[] ()
runFinalizersAfter worker finalizers future = do
  -- Peek future to ensure trivial disposers always run without forking
  isCompleted <- isJust <$> peekFutureSTM future
  if isCompleted
    then
      runFinalizers finalizers
    else
      enqueueForkIO worker do
        await future
        atomicallyC $ liftSTMc $ runFinalizers finalizers
