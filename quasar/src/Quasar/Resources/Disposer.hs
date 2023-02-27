{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Disposer (
  Disposable(..),
  Disposer,
  dispose,
  disposeEventually,
  disposeEventually_,
  newUnmanagedIODisposer,
  newUnmanagedSTMDisposer,
  trivialDisposer,
  isDisposed,

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
  isDisposing,

  -- * ResourceCollector
  ResourceCollector(..),

  -- * Implementing disposers
  IsDisposerElement(..),
  toDisposer,
) where

import Control.Monad (foldM)
import Control.Monad.Catch
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.Fork
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Core
import Quasar.Utils.ShortIO
import Quasar.Utils.TOnce

class Disposable a where
  getDisposer :: a -> Disposer


isDisposed :: Disposable a => a -> Future ()
isDisposed r = toFuture (getDisposer r)


class ToFuture () a => IsDisposerElement a where
  disposerElementKey :: a -> Unique
  disposeEventually# :: a -> STMc NoRetry '[] (Future ())
  beginDispose# :: a -> STMc NoRetry '[] DisposeResult
  beginDispose# disposer = DisposeResultAwait <$> disposeEventually# disposer

toDisposer :: IsDisposerElement a => [a] -> Disposer
toDisposer x = Disposer (DisposerElement <$> x)


newtype Disposer = Disposer [DisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Disposable Disposer where
  getDisposer = id

instance ToFuture () Disposer where
  toFuture (Disposer ds) = foldMap toFuture ds

newtype TDisposer = TDisposer [TDisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Disposable TDisposer where
  getDisposer (TDisposer tds) = toDisposer tds


type DisposerState = TOnce DisposeFnIO (Future ())

data DisposerElement = forall a. IsDisposerElement a => DisposerElement a

instance ToFuture () DisposerElement where
  toFuture (DisposerElement x) = toFuture x

instance IsDisposerElement DisposerElement where
  disposerElementKey (DisposerElement x) = disposerElementKey x
  disposeEventually# (DisposerElement x) = disposeEventually# x
  beginDispose# (DisposerElement x) = beginDispose# x

data IODisposerElement = IODisposerElement Unique TIOWorker ExceptionSink DisposerState

instance ToFuture () IODisposerElement where
  toFuture (IODisposerElement _ _ _ state) = join (toFuture state)

instance IsDisposerElement IODisposerElement where
  disposerElementKey (IODisposerElement key _ _ _) = key
  disposeEventually# disposer = beginDisposeIODisposer disposer

type DisposeFn = ShortIO (Future ())
type DisposeFnIO = IO ()


type STMDisposerState = TOnce (STM ()) (Future ())

data TDisposerElement = TDisposerElement Unique TIOWorker ExceptionSink STMDisposerState

instance ToFuture () TDisposerElement where
  toFuture (TDisposerElement _ _ _ state) = join (toFuture state)

instance IsDisposerElement TDisposerElement where
  disposerElementKey (TDisposerElement key _ _ _) = key
  disposeEventually# disposer = beginDisposeSTMDisposer disposer

newUnmanagedSTMDisposer :: MonadSTMc NoRetry '[] m => STM () -> TIOWorker -> ExceptionSink -> m TDisposer
newUnmanagedSTMDisposer fn worker sink = do
  key <- newUniqueSTM
  element <-  TDisposerElement key worker sink <$> newTOnce fn
  pure $ TDisposer [element]

disposeTDisposer :: MonadSTM m => TDisposer -> m ()
disposeTDisposer (TDisposer elements) = liftSTM $ mapM_ go elements
  where
    go (TDisposerElement _ _ sink state) = do
      future <- mapFinalizeTOnce state startDisposeFn
      -- Elements can also be disposed by a resource manager (on a dedicated thread).
      -- In that case that thread has to be awaited (otherwise this is a no-op).
      readFuture future
      where
        startDisposeFn :: STM () -> STM (Future ())
        startDisposeFn disposeFn = do
          disposeFn `catchAll` throwToExceptionSink sink
          pure (pure ())

beginDisposeSTMDisposer :: forall m. MonadSTMc NoRetry '[] m => TDisposerElement -> m (Future ())
beginDisposeSTMDisposer (TDisposerElement _ worker sink state) = liftSTMc do
  mapFinalizeTOnce state startDisposeFn
  where
    startDisposeFn :: STM () -> STMc NoRetry '[] (Future ())
    startDisposeFn fn = do
      promise <- newPromise
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
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO promise (pure ())
          throwM $ DisposeException ex

-- NOTE TSimpleDisposer is moved to it's own module due to module dependencies

instance Disposable TSimpleDisposer where
  getDisposer (TSimpleDisposer tds) = toDisposer tds

instance IsDisposerElement TSimpleDisposerElement where
  disposerElementKey (TSimpleDisposerElement key _) = key
  disposeEventually# disposer =
    pure () <$ disposeTSimpleDisposerElement disposer


-- | A trivial disposer that does not perform any action when disposed.
trivialDisposer :: Disposer
trivialDisposer = mempty

newUnmanagedIODisposer :: MonadSTMc NoRetry '[] m => IO () -> TIOWorker -> ExceptionSink -> m Disposer
newUnmanagedIODisposer fn worker exChan = do
  key <- newUniqueSTM
  state <- newTOnce fn
  pure $ Disposer [DisposerElement (IODisposerElement key worker exChan state)]


dispose :: (MonadIO m, Disposable r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventually resource)

disposeEventually :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m (Future ())
disposeEventually (getDisposer -> Disposer ds) = liftSTMc do
  mconcat <$> mapM disposeEventually# ds

disposeEventually_ :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m ()
disposeEventually_ resource = void $ disposeEventually resource




beginDisposeIODisposer :: MonadSTMc NoRetry '[] m => IODisposerElement -> m (Future ())
beginDisposeIODisposer (IODisposerElement _ worker exChan disposeState) = liftSTMc do
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFnIO -> STMc NoRetry '[] (Future ())
    startDisposeFn disposeFn = do
      promise <- newPromise
      startShortIOSTM_ (runDisposeFn promise disposeFn) worker exChan
      pure $ join (toFuture promise)

    runDisposeFn :: Promise (Future ()) -> DisposeFnIO -> ShortIO ()
    runDisposeFn promise disposeFn = mask_ $ handleAll exceptionHandler do
      futureE <- unsafeShortIO $ forkFuture disposeFn exChan
      -- Error is redirected to `exceptionHandler`, so the result can be safely ignored
      let future = void (toFuture futureE)
      fulfillPromiseShortIO promise future
      where
        -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
        exceptionHandler :: SomeException -> ShortIO ()
        exceptionHandler ex = do
          fulfillPromiseShortIO promise (pure ())
          throwM $ DisposeException ex


data DisposeResult
  = DisposeResultAwait (Future ())
  | DisposeResultDependencies DisposeDependencies

data DisposeDependencies = DisposeDependencies Unique (Future [DisposeDependencies])


-- * Resource manager

data ResourceManager = ResourceManager {
  resourceManagerKey :: Unique,
  resourceManagerState :: TVar ResourceManagerState,
  resourceManagerIsDisposing :: Promise (),
  resourceManagerIsDisposed :: Promise ()
}

isDisposing :: ResourceManager -> Future ()
isDisposing rm = toFuture (resourceManagerIsDisposing rm)

data ResourceManagerState
  = ResourceManagerNormal (TVar (HashMap Unique DisposerElement)) TIOWorker ExceptionSink
  | ResourceManagerDisposing (Future [DisposeDependencies])
  | ResourceManagerDisposed

instance Disposable ResourceManager where
  getDisposer rm = toDisposer [rm]

instance ToFuture () ResourceManager where
  toFuture rm = toFuture (resourceManagerIsDisposed rm)

instance IsDisposerElement ResourceManager where
  disposerElementKey = resourceManagerKey
  disposeEventually# resourceManager =
    beginDisposeResourceManager resourceManager
  beginDispose# resourceManager =
    DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager


newUnmanagedResourceManagerSTM :: MonadSTMc NoRetry '[] m => TIOWorker -> ExceptionSink -> m ResourceManager
newUnmanagedResourceManagerSTM worker exChan = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources worker exChan)
  resourceManagerIsDisposing <- newPromise
  resourceManagerIsDisposed <- newPromise
  pure ResourceManager {
    resourceManagerKey,
    resourceManagerState,
    resourceManagerIsDisposing,
    resourceManagerIsDisposed
  }


attachResource :: (MonadSTMc NoRetry '[FailedToAttachResource] m, Disposable a) => ResourceManager -> a -> m ()
attachResource resourceManager disposer = liftSTMc @NoRetry @'[FailedToAttachResource] do
  either throwC pure =<< tryAttachResource resourceManager disposer

tryAttachResource :: (MonadSTMc NoRetry '[] m, Disposable a) => ResourceManager -> a -> m (Either FailedToAttachResource ())
tryAttachResource resourceManager (getDisposer -> Disposer ds) = liftSTMc do
  sequence_ <$> mapM (tryAttachDisposer resourceManager) ds

tryAttachDisposer :: ResourceManager -> DisposerElement -> STMc NoRetry '[] (Either FailedToAttachResource ())
tryAttachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ _ -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        attachedResult <- readOrAttachToFuture_ disposer \() -> finalizerCallback
        case attachedResult of
          Just () -> pure () -- Already disposed
          Nothing -> modifyTVar attachedResources (HM.insert key disposer)
      pure $ Right ()
    _ -> pure $ Left FailedToAttachResource
  where
    key :: Unique
    key = disposerElementKey disposer
    finalizerCallback :: STMc NoRetry '[] ()
    finalizerCallback = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources _ _ -> modifyTVar attachedResources (HM.delete key)
      -- No resource detach is required in other states, since all resources are disposed soon
      -- (awaiting each resource should be cheaper than modifying the HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManager :: ResourceManager -> STMc NoRetry '[] (Future ())
beginDisposeResourceManager rm = do
  void $ beginDisposeResourceManagerInternal rm
  pure $ toFuture (resourceManagerIsDisposed rm)

beginDisposeResourceManagerInternal :: ResourceManager -> STMc NoRetry '[] DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources worker exChan -> do
      dependenciesVar <- newPromise

      -- write before fulfilling the promise since the promise has callbacks
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toFuture dependenciesVar))
      tryFulfillPromise_ (resourceManagerIsDisposing rm) ()

      attachedDisposers <- HM.elems <$> readTVar attachedResources
      startShortIOSTM_ (void $ forkIOShortIO (disposeThread dependenciesVar attachedDisposers)) worker exChan
      pure $ DisposeDependencies rmKey (toFuture dependenciesVar)
    ResourceManagerDisposing deps -> pure $ DisposeDependencies rmKey deps
    ResourceManagerDisposed -> pure $ DisposeDependencies rmKey mempty
  where
    disposeThread :: Promise [DisposeDependencies] -> [DisposerElement] -> IO ()
    disposeThread dependenciesVar attachedDisposers = do
      -- Begin to dispose all attached resources
      results <- mapM (atomicallyC . liftSTMc . beginDispose#) attachedDisposers
      -- Await direct resource awaitables and collect indirect dependencies
      dependencies <- await (collectDependencies results)
      -- Publish "direct dependencies complete"-status
      fulfillPromiseIO dependenciesVar dependencies
      -- Await indirect dependencies
      awaitDisposeDependencies $ DisposeDependencies rmKey (pure dependencies)
      -- Set state to disposed
      atomicallyC do

        -- write before fulfilling the promise since the promise has callbacks
        writeTVar (resourceManagerState rm) ResourceManagerDisposed
        tryFulfillPromise_ (resourceManagerIsDisposed rm) ()

    rmKey :: Unique
    rmKey = resourceManagerKey rm

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


-- * ResourceCollector

class Monad m => ResourceCollector m where
  collectResource :: Disposable a => a -> m ()


--unmanagedCaptureResources :: ResourceT STM () -> STM Disposer
--unmanagedCaptureResources = undefined
--
--unmanagedCaptureResourcesIO :: ResourceT IO () -> IO Disposer
--unmanagedCaptureResourcesIO = undefined
