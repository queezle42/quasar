{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE UndecidableInstances #-}

module Quasar.Disposer.Core (
  -- * Disposer api
  Disposable(..),
  Disposer,
  dispose,
  disposeEventually,
  disposeEventually_,
  newDisposer,
  newDisposerIO,
  isDisposed,
  trivialDisposer,
  isTrivialDisposer,

  -- ** STM variants
  TDisposable(..),
  TDisposer,
  disposeTDisposer,
  disposeSTM,
  newTDisposer,
  newSTMDisposer,
  newRetryTDisposer,
  isTrivialTDisposer,

  -- * Resource manager
  ResourceManager,
  newResourceManager,
  attachResource,
  tryAttachResource,
  isDisposing,

  -- * ResourceCollector
  ResourceCollector(..),

  -- * Implementing disposers
  IsDisposerElement(..),
  mkDisposer,
  IsTDisposerElement(..),
  mkTDisposer,
  DisposeResult(..),
  DisposeDependencies(..),
  flattenDisposeDependencies,
  beginDisposeDisposer,
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
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.TOnce
import Quasar.Exceptions.ExceptionSink (loggingExceptionSink)

class Disposable a where
  getDisposer :: a -> Disposer

instance Disposable (Disposer, a) where
  getDisposer (disposer, _) = disposer


isDisposed :: Disposable a => a -> Future '[] ()
isDisposed r = toFuture (getDisposer r)


class ToFuture '[] () a => IsDisposerElement a where
  disposerElementKey :: a -> Unique
  disposeEventually# :: a -> STMc NoRetry '[] (Future '[] ())
  beginDispose# :: a -> STMc NoRetry '[] DisposeResult
  beginDispose# disposer = DisposeResultAwait <$> disposeEventually# disposer

mkDisposer :: IsDisposerElement a => [a] -> Disposer
mkDisposer x = Disposer (DisposerElement <$> x)


newtype Disposer = Disposer [DisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Disposable Disposer where
  getDisposer = id

instance ToFuture '[] () Disposer where
  toFuture (Disposer ds) = foldMap toFuture ds


data DisposerElement = forall a. IsDisposerElement a => DisposerElement a

instance ToFuture '[] () DisposerElement where
  toFuture (DisposerElement x) = toFuture x

instance IsDisposerElement DisposerElement where
  disposerElementKey (DisposerElement x) = disposerElementKey x
  disposeEventually# (DisposerElement x) = disposeEventually# x
  beginDispose# (DisposerElement x) = beginDispose# x

data IODisposerElement = IODisposerElement Unique ExceptionSink (TOnce DisposeFnIO (Future '[] ()))

instance ToFuture '[] () IODisposerElement where
  toFuture (IODisposerElement _ _ state) = join (toFuture state)

instance IsDisposerElement IODisposerElement where
  disposerElementKey (IODisposerElement key _ _) = key
  disposeEventually# (IODisposerElement _ sink disposeState) = do
    mapFinalizeTOnce disposeState \fn ->
      void . tryAllC <$> forkFutureSTM (wrapDisposeException fn) sink

wrapDisposeException :: MonadCatch m => m a -> m a
wrapDisposeException fn = fn `catchAll` \ex -> throwM (DisposeException ex)

type DisposeFnIO = IO ()


class Disposable a => TDisposable a where
  getTDisposer :: a -> TDisposer

instance TDisposable (TDisposer, a) where
  getTDisposer (disposer, _) = disposer

mkTDisposer :: IsTDisposerElement a => [a] -> TDisposer
mkTDisposer x = TDisposer (TDisposerElement <$> x)

newtype TDisposer = TDisposer [TDisposerElement]
  deriving newtype (Semigroup, Monoid)

instance Disposable TDisposer where
  getDisposer (TDisposer tds) = mkDisposer tds

instance Disposable (TDisposer, a) where
  getDisposer (disposer, _) = getDisposer disposer

class IsDisposerElement a => IsTDisposerElement a where
  -- | In case of reentry this might return before disposing is completed.
  disposeTDisposerElement :: a -> STMc NoRetry '[] ()

data TDisposerElement =
  forall a. IsTDisposerElement a => TDisposerElement a

instance IsTDisposerElement TDisposerElement where
  disposeTDisposerElement (TDisposerElement x) = disposeTDisposerElement x

instance IsDisposerElement TDisposerElement where
  disposerElementKey (TDisposerElement x) = disposerElementKey x
  disposeEventually# (TDisposerElement x) = disposeEventually# x
  beginDispose# (TDisposerElement x) = beginDispose# x

instance ToFuture '[] () TDisposerElement where
  toFuture (TDisposerElement x) = toFuture x

-- | In case of reentry this might return before disposing is completed.
disposeSTM :: (TDisposable a, MonadSTMc NoRetry '[] m) => a -> m ()
disposeSTM x =
  let TDisposer elements = getTDisposer x
  in liftSTMc (mapM_ disposeTDisposerElement elements)


data TSimpleDisposerState
  = TSimpleDisposerNormal (STMc NoRetry '[] ()) (CallbackRegistry (Either (Ex '[]) ()))
  | TSimpleDisposerDisposing (CallbackRegistry (Either (Ex '[]) ()))
  | TSimpleDisposerDisposed

data TSimpleDisposerElement = TSimpleDisposerElement Unique (TVar TSimpleDisposerState)

newTSimpleDisposerElement :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TSimpleDisposerElement
newTSimpleDisposerElement fn = liftSTMc do
  key <- newUniqueSTM
  isDisposedRegistry <- newCallbackRegistry
  stateVar <- newTVar (TSimpleDisposerNormal fn isDisposedRegistry)
  pure (TSimpleDisposerElement key stateVar)

-- | In case of reentry this will return without calling the dispose hander again.
disposeTSimpleDisposerElement :: TSimpleDisposerElement -> STMc NoRetry '[] ()
disposeTSimpleDisposerElement (TSimpleDisposerElement _ var) =
  readTVar var >>= \case
    TSimpleDisposerNormal fn isDisposedRegistry -> do
      writeTVar var (TSimpleDisposerDisposing isDisposedRegistry)
      fn
      writeTVar var TSimpleDisposerDisposed
      callCallbacks isDisposedRegistry (Right ())
    TSimpleDisposerDisposing _ ->
      -- Doing nothing results in the documented behavior.
      pure ()
    TSimpleDisposerDisposed -> pure ()

instance ToFuture '[] () TSimpleDisposerElement

instance IsFuture '[] () TSimpleDisposerElement where
  readFuture# (TSimpleDisposerElement _ stateVar) = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> pure (Right ())
      _ -> retry

  readOrAttachToFuture# (TSimpleDisposerElement _ stateVar) callback = do
    readTVar stateVar >>= \case
      TSimpleDisposerDisposed -> pure (Right (Right ()))
      TSimpleDisposerDisposing registry -> Left <$> registerDisposedCallback registry
      TSimpleDisposerNormal _ registry -> Left <$> registerDisposedCallback registry
    where
      registerDisposedCallback registry = do
        -- NOTE Using mfix to get the disposer is a safe because the registered
        -- method won't be called immediately.
        -- Modifying the callback to deregister itself is an inefficient hack
        -- that could be improved by writing a custom registry.
        mfix \disposer -> do
          registerCallback registry \value -> do
            callback value
            disposeTDisposer disposer

instance ToFuture '[] () TDisposer where
  toFuture (TDisposer elements) = mconcat $ toFuture <$> elements


data RetryDisposerElement canRetry
  = canRetry ~ Retry => RetryTDisposerElement Unique (TOnce (STMc Retry '[] ()) (Future '[] ()))

instance ToFuture '[] () (RetryDisposerElement canRetry) where
  toFuture (RetryTDisposerElement _ state) = join (toFuture state)

instance IsDisposerElement (RetryDisposerElement canRetry) where
  disposerElementKey (RetryTDisposerElement key _) = key
  disposeEventually# (RetryTDisposerElement _ state) =
    mapFinalizeTOnce state \fn ->
      void . toFuture <$> forkSTMcOnRetry fn

wrapSTM :: ExceptionSink -> STM () -> STMc Retry '[] ()
wrapSTM sink fn =
  catchAllSTMc @Retry @'[SomeException]
    (liftSTM fn)
    \ex -> throwToExceptionSink sink (DisposeException (toException ex))

newSTMDisposer :: MonadSTMc NoRetry '[] m => STM () -> ExceptionSink -> m Disposer
newSTMDisposer fn sink = do
  key <- newUniqueSTM
  element <- DisposerElement . RetryTDisposerElement key <$> newTOnce (wrapSTM sink fn)
  pure $ Disposer [element]

newTDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TDisposer
newTDisposer fn = do
  element <- newTSimpleDisposerElement fn
  pure (TDisposer [TDisposerElement element])

-- | In case of reentry this might return before disposing is completed.
disposeTDisposer :: MonadSTMc NoRetry '[] m => TDisposer -> m ()
disposeTDisposer (TDisposer elements) = liftSTMc $ mapM_ disposeTDisposerElement elements


newRetryTDisposer :: MonadSTMc NoRetry '[] m => STMc Retry '[] () -> m Disposer
newRetryTDisposer fn = do
  key <- newUniqueSTM
  element <- DisposerElement . RetryTDisposerElement key <$> newTOnce fn
  pure $ Disposer [element]


instance IsDisposerElement TSimpleDisposerElement where
  disposerElementKey (TSimpleDisposerElement key _) = key
  disposeEventually# disposer =
    -- NOTE On reentrant call the future does not reflect not-yet disposed
    -- state.
    pure () <$ disposeTSimpleDisposerElement disposer

instance IsTDisposerElement TSimpleDisposerElement where
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
isTrivialTDisposer :: TDisposer -> Bool
isTrivialTDisposer (TDisposer []) = True
isTrivialTDisposer _ = False

newDisposer :: MonadSTMc NoRetry '[] m => IO () -> ExceptionSink -> m Disposer
newDisposer fn exChan = do
  key <- newUniqueSTM
  state <- newTOnce fn
  pure $ Disposer [DisposerElement (IODisposerElement key exChan state)]

newDisposerIO :: MonadIO m => IO () -> ExceptionSink -> m Disposer
newDisposerIO fn exChan = do
  key <- newUnique
  state <- newTOnceIO fn
  pure $ Disposer [DisposerElement (IODisposerElement key exChan state)]


dispose :: (MonadIO m, Disposable r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventually resource)

disposeEventually :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m (Future '[] ())
disposeEventually (getDisposer -> Disposer ds) = liftSTMc do
  mconcat <$> mapM disposeEventually# ds

disposeEventually_ :: (Disposable a, MonadSTMc NoRetry '[] m) => a -> m ()
disposeEventually_ resource = void $ disposeEventually resource


data DisposeResult
  = DisposeResultAwait (Future '[] ())
  | DisposeResultDependencies DisposeDependencies

data DisposeDependencies = DisposeDependencies Unique (Future '[] [DisposeDependencies])

-- Combine the futures of all DisposeDependencies. The resulting future might be
-- expensive.
flattenDisposeDependencies :: DisposeDependencies -> Future '[] ()
flattenDisposeDependencies = void . go mempty
  where
    go :: HashSet Unique -> DisposeDependencies -> Future '[] (HashSet Unique)
    go keys (DisposeDependencies key deps)
      | HashSet.member key keys = pure keys -- loop detection: dependencies were already handled
      | otherwise = do
          dependencies <- deps
          foldM go (HashSet.insert key keys) dependencies

beginDisposeDisposer :: Disposer -> STMc NoRetry '[] (Future '[] [DisposeDependencies])
beginDisposeDisposer (Disposer elements) = do
  mapM beginDispose# elements <&> \results -> do
    catMaybes <$> forM results \case
      DisposeResultAwait future -> Nothing <$ future
      DisposeResultDependencies deps -> pure (Just deps)


-- * Resource manager

data ResourceManager = ResourceManager {
  resourceManagerKey :: Unique,
  resourceManagerState :: TVar ResourceManagerState,
  resourceManagerIsDisposing :: Promise (),
  resourceManagerIsDisposed :: Promise ()
}

isDisposing :: ResourceManager -> Future '[] ()
isDisposing rm = toFuture (resourceManagerIsDisposing rm)

data ResourceManagerState
  = ResourceManagerNormal (TVar (HashMap Unique DisposerElement))
  | ResourceManagerDisposing (Future '[] [DisposeDependencies])
  | ResourceManagerDisposed

instance Disposable ResourceManager where
  getDisposer rm = mkDisposer [rm]

instance ToFuture '[] () ResourceManager where
  toFuture rm = toFuture (resourceManagerIsDisposed rm)

instance IsDisposerElement ResourceManager where
  disposerElementKey = resourceManagerKey
  disposeEventually# resourceManager = do
    void $ beginDisposeResourceManagerInternal resourceManager
    pure $ toFuture (resourceManagerIsDisposed resourceManager)
  beginDispose# resourceManager =
    DisposeResultDependencies <$> beginDisposeResourceManagerInternal resourceManager


newResourceManager :: MonadSTMc NoRetry '[] m => m ResourceManager
newResourceManager = do
  resourceManagerKey <- newUniqueSTM
  attachedResources <- newTVar mempty
  resourceManagerState <- newTVar (ResourceManagerNormal attachedResources)
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
    ResourceManagerNormal attachedResources -> do
      alreadyAttached <- isJust . HM.lookup key <$> readTVar attachedResources
      unless alreadyAttached do
        attachedResult <- readOrAttachToFuture_ disposer \_ -> finalizerCallback
        case attachedResult of
          Just _ -> pure () -- Already disposed
          Nothing -> modifyTVar attachedResources (HM.insert key disposer)
      pure $ Right ()
    _ -> pure $ Left FailedToAttachResource
  where
    key :: Unique
    key = disposerElementKey disposer
    finalizerCallback :: STMc NoRetry '[] ()
    finalizerCallback = readTVar (resourceManagerState resourceManager) >>= \case
      ResourceManagerNormal attachedResources -> modifyTVar attachedResources (HM.delete key)
      -- No resource detach is required in other states, since all resources are disposed soon
      -- (awaiting each resource should be cheaper than modifying the HashMap until it is empty).
      _ -> pure ()


beginDisposeResourceManagerInternal :: ResourceManager -> STMc NoRetry '[] DisposeDependencies
beginDisposeResourceManagerInternal rm = do
  readTVar (resourceManagerState rm) >>= \case
    ResourceManagerNormal attachedResources -> do
      dependenciesVar <- newPromise

      -- write before fulfilling the promise since the promise has callbacks
      writeTVar (resourceManagerState rm) (ResourceManagerDisposing (toFuture dependenciesVar))
      tryFulfillPromise_ (resourceManagerIsDisposing rm) ()

      attachedDisposers <- HM.elems <$> readTVar attachedResources
      forkSTM_ (disposeThread dependenciesVar attachedDisposers) brokenDisposerExceptionSink
      pure $ DisposeDependencies rmKey (toFuture dependenciesVar)
    ResourceManagerDisposing deps -> pure $ DisposeDependencies rmKey deps
    ResourceManagerDisposed -> pure $ DisposeDependencies rmKey mempty
  where
    -- TODO prefix with message
    brokenDisposerExceptionSink = loggingExceptionSink

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

    collectDependencies :: [DisposeResult] -> Future '[] [DisposeDependencies]
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
