{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Resources.Disposer (
  -- * Disposer api
  Disposable(..),
  Disposer,
  dispose,
  disposeEventually,
  disposeEventually_,
  newUnmanagedIODisposer,
  isDisposed,
  trivialDisposer,
  isTrivialDisposer,

  -- ** STM variants
  TDisposable(..),
  TDisposer,
  disposeSTM,
  newUnmanagedSTMDisposer,
  newUnmanagedNoRetryTDisposer,
  newUnmanagedRetryTDisposer,
  isTrivialTDisposer,

  -- ** Legacy/internal STM variants
  TSimpleDisposer,
  newUnmanagedTSimpleDisposer,
  disposeTSimpleDisposer,
  isTrivialTSimpleDisposer,

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
  IsTDisposerElement(..),
  toTDisposer,
) where

import Control.Monad (foldM)
import Control.Monad.Catch
import Control.Monad.Trans (MonadTrans (lift))
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Async.Fork
import Quasar.Exceptions
import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Core
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


type DisposerState = TOnce DisposeFnIO (Future ())

data DisposerElement = forall a. IsDisposerElement a => DisposerElement a

instance ToFuture () DisposerElement where
  toFuture (DisposerElement x) = toFuture x

instance IsDisposerElement DisposerElement where
  disposerElementKey (DisposerElement x) = disposerElementKey x
  disposeEventually# (DisposerElement x) = disposeEventually# x
  beginDispose# (DisposerElement x) = beginDispose# x

data IODisposerElement = IODisposerElement Unique ExceptionSink DisposerState

instance ToFuture () IODisposerElement where
  toFuture (IODisposerElement _ _ state) = join (toFuture state)

instance IsDisposerElement IODisposerElement where
  disposerElementKey (IODisposerElement key _ _) = key
  disposeEventually# (IODisposerElement _ sink disposeState) = do
    mapFinalizeTOnce disposeState \fn ->
      void . toFuture <$> forkFutureSTM (wrapDisposeException fn) sink

wrapDisposeException :: MonadCatch m => m a -> m a
wrapDisposeException fn = (fn `catchAll` \ex -> throwM (DisposeException ex))

type DisposeFnIO = IO ()


class Disposable a => TDisposable canRetry a | a -> canRetry where
  getTDisposer :: a -> TDisposer canRetry

toTDisposer :: IsTDisposerElement canRetry a => [a] -> TDisposer canRetry
toTDisposer x = TDisposer (TDisposerElement <$> x)

newtype TDisposer canRetry = TDisposer [TDisposerElement canRetry]
  deriving newtype (Semigroup, Monoid)

instance Disposable (TDisposer canRetry) where
  getDisposer (TDisposer tds) = toDisposer tds

class IsDisposerElement a => IsTDisposerElement canRetry a | a -> canRetry where
  disposeTDisposerElement :: a -> STMc canRetry '[] ()

data TDisposerElement canRetry =
  forall a. IsTDisposerElement canRetry a => TDisposerElement a

instance IsTDisposerElement canRetry (TDisposerElement canRetry) where
  disposeTDisposerElement (TDisposerElement x) = disposeTDisposerElement x

instance IsDisposerElement (TDisposerElement canRetry) where
  disposerElementKey (TDisposerElement x) = disposerElementKey x
  disposeEventually# (TDisposerElement x) = disposeEventually# x
  beginDispose# (TDisposerElement x) = beginDispose# x

instance ToFuture () (TDisposerElement canRetry) where
  toFuture (TDisposerElement x) = toFuture x

disposeSTM :: forall canRetry a m. (TDisposable canRetry a, MonadSTMc canRetry '[] m) => a -> m ()
disposeSTM x =
  let TDisposer elements = getTDisposer x
  in liftSTMc (mapM_ disposeTDisposerElement elements)

data RetryTDisposerElement canRetry
  = canRetry ~ Retry => RetryTDisposerElement Unique (TOnce (STMc Retry '[] ()) (Future ()))

instance ToFuture () (RetryTDisposerElement canRetry) where
  toFuture (RetryTDisposerElement _ state) = join (toFuture state)

instance IsDisposerElement (RetryTDisposerElement canRetry) where
  disposerElementKey (RetryTDisposerElement key _) = key
  disposeEventually# (RetryTDisposerElement _ state) =
    mapFinalizeTOnce state \fn ->
      void . toFuture <$> forkSTMcOnRetry fn

instance IsTDisposerElement canRetry (RetryTDisposerElement canRetry) where
  disposeTDisposerElement (RetryTDisposerElement _ state) = do
    future <- mapFinalizeTOnce state startDisposeFn
    -- Elements can also be disposed by a resource manager (on a dedicated thread).
    -- In that case that thread has to be awaited (otherwise this is a no-op).
    readFuture future
    where
      startDisposeFn :: STMc Retry '[] () -> STMc Retry '[] (Future ())
      startDisposeFn disposeFn = do
        disposeFn
        pure (pure ())

wrapSTM :: ExceptionSink -> STM () -> STMc Retry '[] ()
wrapSTM sink fn =
  catchAllSTMc @Retry @'[SomeException]
    (liftSTM fn)
    \ex -> throwToExceptionSink sink (DisposeException ex)

newUnmanagedSTMDisposer :: MonadSTMc NoRetry '[] m => STM () -> ExceptionSink -> m (TDisposer Retry)
newUnmanagedSTMDisposer fn sink = do
  key <- newUniqueSTM
  element <-  TDisposerElement . RetryTDisposerElement key <$> newTOnce (wrapSTM sink fn)
  pure $ TDisposer [element]

newUnmanagedNoRetryTDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m (TDisposer NoRetry)
newUnmanagedNoRetryTDisposer fn = do
  TSimpleDisposer elements <- newUnmanagedTSimpleDisposer fn
  pure (toTDisposer elements)


newUnmanagedRetryTDisposer :: MonadSTMc NoRetry '[] m => STMc Retry '[] () -> m (TDisposer Retry)
newUnmanagedRetryTDisposer fn = do
  key <- newUniqueSTM
  element <-  TDisposerElement . RetryTDisposerElement key <$> newTOnce fn
  pure $ TDisposer [element]


-- NOTE TSimpleDisposer is moved to it's own module due to module dependencies

instance Disposable TSimpleDisposer where
  getDisposer (TSimpleDisposer tds) = toDisposer tds

instance IsDisposerElement TSimpleDisposerElement where
  disposerElementKey (TSimpleDisposerElement key _) = key
  disposeEventually# disposer =
    pure () <$ disposeTSimpleDisposerElement disposer

instance IsTDisposerElement NoRetry TSimpleDisposerElement where
  disposeTDisposerElement = disposeTSimpleDisposerElement


-- | A trivial disposer that does not perform any action when disposed.
trivialDisposer :: Disposer
trivialDisposer = mempty

-- | Check if a disposer is a trivial disposer, i.e. a disposer that does not
-- perform any action when disposed.
isTrivialDisposer :: Disposer -> Bool
isTrivialDisposer (Disposer []) = True
isTrivialDisposer _ = False

-- | Check if a disposer is a trivial disposer, i.e. a disposer that does not
-- perform any action when disposed.
isTrivialTDisposer :: TDisposer canRetry -> Bool
isTrivialTDisposer (TDisposer []) = True
isTrivialTDisposer _ = False

newUnmanagedIODisposer :: MonadSTMc NoRetry '[] m => IO () -> ExceptionSink -> m Disposer
newUnmanagedIODisposer fn exChan = do
  key <- newUniqueSTM
  state <- newTOnce fn
  pure $ Disposer [DisposerElement (IODisposerElement key exChan state)]


dispose :: (MonadIO m, Disposable r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventually resource)

disposeEventually :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m (Future ())
disposeEventually (getDisposer -> Disposer ds) = liftSTMc do
  mconcat <$> mapM disposeEventually# ds

disposeEventually_ :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m ()
disposeEventually_ resource = void $ disposeEventually resource


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
  = ResourceManagerNormal (TVar (HashMap Unique DisposerElement)) ExceptionSink
  | ResourceManagerDisposing (Future [DisposeDependencies])
  | ResourceManagerDisposed

instance Disposable ResourceManager where
  getDisposer rm = toDisposer [rm]

instance ToFuture () ResourceManager where
  toFuture rm = toFuture (resourceManagerIsDisposed rm)

instance IsDisposerElement ResourceManager where
  disposerElementKey = resourceManagerKey
  disposeEventually# resourceManager = do
    void $ beginDisposeResourceManagerInternal resourceManager
    pure $ toFuture (resourceManagerIsDisposed resourceManager)
  beginDispose# resourceManager =
    DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager


newUnmanagedResourceManagerSTM :: MonadSTMc NoRetry '[] m => ExceptionSink -> m ResourceManager
newUnmanagedResourceManagerSTM exChan = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources exChan)
  resourceManagerIsDisposing <- newPromise
  resourceManagerIsDisposed <- newPromise
  pure ResourceManager {
    resourceManagerKey,
    resourceManagerState,
    resourceManagerIsDisposing,
    resourceManagerIsDisposed
  }


attachResource :: HasCallStack => (MonadSTMc NoRetry '[FailedToAttachResource] m, Disposable a) => ResourceManager -> a -> m ()
attachResource resourceManager disposer = liftSTMc @NoRetry @'[FailedToAttachResource] do
  either throwC pure =<< tryAttachResource resourceManager disposer

tryAttachResource :: HasCallStack => (MonadSTMc NoRetry '[] m, Disposable a) => ResourceManager -> a -> m (Either FailedToAttachResource ())
tryAttachResource resourceManager (getDisposer -> Disposer ds) = liftSTMc do
  sequence_ <$> mapM (tryAttachDisposer resourceManager) ds

tryAttachDisposer :: HasCallStack => ResourceManager -> DisposerElement -> STMc NoRetry '[] (Either FailedToAttachResource ())
tryAttachDisposer resourceManager disposer = do
  readTVar (resourceManagerState resourceManager) >>= \case
    ResourceManagerNormal attachedResources _ -> do
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
      ResourceManagerNormal attachedResources _ -> modifyTVar attachedResources (HM.delete key)
      -- No resource detach is required in other states, since all resources are disposed soon
      -- (awaiting each resource should be cheaper than modifying the HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManagerInternal :: ResourceManager -> STMc NoRetry '[] DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources exChan -> do
      dependenciesVar <- newPromise

      -- write before fulfilling the promise since the promise has callbacks
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toFuture dependenciesVar))
      tryFulfillPromise_ (resourceManagerIsDisposing rm) ()

      attachedDisposers <- HM.elems <$> readTVar attachedResources
      forkSTM_ (disposeThread dependenciesVar attachedDisposers) exChan
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
  collectResource :: (Disposable a, HasCallStack) => a -> m ()

instance {-# OVERLAPPABLE #-} (ResourceCollector m, MonadTrans t, Monad (t m)) => ResourceCollector (t m) where
  collectResource = lift . collectResource
