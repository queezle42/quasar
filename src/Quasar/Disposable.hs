module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  dispose,
  disposeEventually,
  disposeEventually_,

  newDisposable,
  noDisposable,

  -- ** Async Disposable
  newAsyncDisposable,

  -- ** STM disposable
  STMDisposable,
  newSTMDisposable,
  newSTMDisposable',
  disposeSTMDisposable,

  -- * Implementation internals
  DisposeResult(..),
  ResourceManagerResult(..),
  DisposableFinalizers,
  newDisposableFinalizers,
  newDisposableFinalizersSTM,
  defaultRegisterFinalizer,
  defaultRunFinalizers,
  awaitResourceManagerResult,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import GHC.Conc (unsafeIOToSTM)
import Quasar.Awaitable
import Quasar.Prelude


-- * Disposable

class IsDisposable a where
  -- | Convert an `IsDisposable`-Object to a `Disposable`.
  --
  -- When implementing the `IsDisposable`-class this can be used to defer the dispose behavior to a disposable created
  -- by e.g. `newDisposable`.
  toDisposable :: a -> Disposable
  toDisposable = Disposable

  -- | Begin to dispose (/release) resource(s).
  --
  -- The implementation has to be idempotent, i.e. calling `beginDispose` once or multiple times should have the same
  -- effect.
  --
  -- `beginDispose` must be called in masked state.
  --
  -- `beginDispose` must not block for an unbounded time.
  --
  -- TODO document finalizers (finalizers also have to run when an exception is thrown)
  beginDispose :: a -> IO DisposeResult
  beginDispose = beginDispose . toDisposable

  isDisposed :: a -> Awaitable ()
  isDisposed = isDisposed . toDisposable

  -- | Finalizers MUST NOT throw exceptions.
  --
  -- The boolean returned by register finalizer indicates if the operation was successful.
  registerFinalizer :: a -> STM () -> STM Bool
  registerFinalizer = registerFinalizer . toDisposable

  {-# MINIMAL toDisposable | (beginDispose, isDisposed, registerFinalizer) #-}

dispose :: MonadIO m => IsDisposable a => a -> m ()
dispose disposable = liftIO do
  uninterruptibleMask_ (beginDispose disposable) >>= \case
    DisposeResultDisposed -> pure ()
    (DisposeResultAwait awaitable) -> await awaitable
    (DisposeResultResourceManager result) -> awaitResourceManagerResult result

-- | Begin to dispose a resource.
disposeEventually :: (IsDisposable a, MonadIO m) => a -> m (Awaitable ())
disposeEventually disposable = do
  disposeEventually_ disposable
  pure $ isDisposed disposable

-- | Begin to dispose a resource.
disposeEventually_ :: (IsDisposable a, MonadIO m) => a -> m ()
disposeEventually_ disposable = liftIO do
  uninterruptibleMask_ $ void $ beginDispose disposable

awaitResourceManagerResult :: forall m. MonadAwait m => ResourceManagerResult -> m ()
awaitResourceManagerResult = void . go mempty
  where
    go :: HashSet Unique -> ResourceManagerResult -> m (HashSet Unique)
    go keys (ResourceManagerResult key awaitable)
      | HashSet.member key keys = pure keys -- resource manager was encountered before
      | otherwise = do
        dependencies <- await awaitable
        foldM go (HashSet.insert key keys) dependencies


data DisposeResult
  = DisposeResultDisposed
  | DisposeResultAwait (Awaitable ())
  | DisposeResultResourceManager ResourceManagerResult

data ResourceManagerResult = ResourceManagerResult Unique (Awaitable [ResourceManagerResult])


instance IsDisposable a => IsDisposable (Maybe a) where
  toDisposable = maybe noDisposable toDisposable


data Disposable = forall a. IsDisposable a => Disposable a

instance IsDisposable Disposable where
  beginDispose (Disposable x) = beginDispose x
  isDisposed (Disposable x) = isDisposed x
  registerFinalizer (Disposable x) = registerFinalizer x
  toDisposable = id

instance IsAwaitable () Disposable where
  toAwaitable = isDisposed



data IODisposable = IODisposable Unique (TMVar (IO ())) DisposableFinalizers (AsyncVar ())

instance IsDisposable IODisposable where
  beginDispose (IODisposable key actionVar finalizers resultVar) = do
    -- This is only safe when run in masked state
    atomically (tryTakeTMVar actionVar) >>= mapM_ \action -> do
      result <- try action
      atomically do
        putAsyncVarEitherSTM_ resultVar result
        defaultRunFinalizers finalizers
    -- Await so concurrent `beginDispose` calls don't exit too early
    await resultVar
    pure DisposeResultDisposed

  isDisposed (IODisposable _ _ _ resultVar) = toAwaitable resultVar `catchAll` \_ -> pure ()

  registerFinalizer (IODisposable _ _ finalizers _) = defaultRegisterFinalizer finalizers


-- | Create a new disposable from an IO action. Is is guaranteed, that the IO action will only be called once (even when
-- `dispose` is called multiple times).
--
-- The action must not block for an unbound time.
newDisposable :: IO () -> STM Disposable
newDisposable disposeAction = do
  key <- newUniqueSTM
  fmap toDisposable $ IODisposable key <$> newTMVar disposeAction <*> newDisposableFinalizersSTM <*> newAsyncVarSTM


data AsyncDisposable = AsyncDisposable Unique (TMVar (IO ())) DisposableFinalizers (AsyncVar ())

instance IsDisposable AsyncDisposable where
  beginDispose (AsyncDisposable key actionVar finalizers resultVar) = do
    -- This is only safe when run in masked state
    atomically (tryTakeTMVar actionVar) >>= mapM_ \action -> do
      void $ forkIO do
        result <- try action
        atomically do
          putAsyncVarEitherSTM_ resultVar result
          defaultRunFinalizers finalizers
    pure $ DisposeResultAwait $ await resultVar

  isDisposed (AsyncDisposable _ _ _ resultVar) = toAwaitable resultVar `catchAll` \_ -> pure ()

  registerFinalizer (AsyncDisposable _ _ finalizers _) = defaultRegisterFinalizer finalizers

-- | Create a new disposable from an IO action. The action will be run asynchrously. Is is guaranteed, that the IO
-- action will only be called once (even when `dispose` is called multiple times).
--
-- The action must not block for an unbound time.
newAsyncDisposable :: IO () -> STM Disposable
newAsyncDisposable disposeAction = do
  key <- newUniqueSTM
  fmap toDisposable $ AsyncDisposable key <$> newTMVar disposeAction <*> newDisposableFinalizersSTM <*> newAsyncVarSTM



data STMDisposable = STMDisposable Unique (TMVar (STM ())) DisposableFinalizers (AsyncVar ())

instance IsDisposable STMDisposable where
  beginDispose (STMDisposable key actionVar finalizers resultVar) = do
    -- This is only safe when run in masked state
    atomically (tryTakeTMVar actionVar) >>= mapM_ \action -> do
      atomically do
        result <- try action
        putAsyncVarEitherSTM_ resultVar result
        defaultRunFinalizers finalizers
    -- Await so concurrent `beginDispose` calls don't exit too early
    await resultVar
    pure DisposeResultDisposed

  isDisposed (STMDisposable _ _ _ resultVar) = toAwaitable resultVar `catchAll` \_ -> pure ()

  registerFinalizer (STMDisposable _ _ finalizers _) = defaultRegisterFinalizer finalizers

-- | Create a new disposable from an STM action. Is is guaranteed, that the STM action will only be called once (even
-- when `dispose` is called multiple times).
--
-- The action must not block (retry) for an unbound time.
newSTMDisposable :: STM () -> STM Disposable
newSTMDisposable disposeAction = toDisposable <$> newSTMDisposable' disposeAction

-- | Create a new disposable from an STM action. Is is guaranteed, that the STM action will only be called once (even
-- when `dispose` is called multiple times).
--
-- The action must not block (retry) for an unbound time.
--
-- This variant of `newSTMDisposable` returns an unboxed `STMDisposable` which can be disposed from `STM` by using
-- `disposeSTMDisposable`.
newSTMDisposable' :: STM () -> STM STMDisposable
newSTMDisposable' disposeAction = do
  key <- unsafeIOToSTM newUnique
  STMDisposable key <$> newTMVar disposeAction <*> newDisposableFinalizersSTM <*> newAsyncVarSTM

disposeSTMDisposable :: STMDisposable -> STM ()
disposeSTMDisposable (STMDisposable key actionVar finalizers resultVar) = do
  tryTakeTMVar actionVar >>= \case
    Just action -> do
      result <- try action
      putAsyncVarEitherSTM_ resultVar result
      defaultRunFinalizers finalizers
    Nothing -> readAsyncVarSTM resultVar


data EmptyDisposable = EmptyDisposable

instance IsDisposable EmptyDisposable where
  beginDispose EmptyDisposable = pure DisposeResultDisposed
  isDisposed _ = pure ()
  registerFinalizer _ _ = pure False



-- | A `Disposable` for which `dispose` is a no-op and which reports as already disposed.
noDisposable :: Disposable
noDisposable = toDisposable EmptyDisposable



-- * Implementation internals

newtype DisposableFinalizers = DisposableFinalizers (TMVar [STM ()])

newDisposableFinalizers :: IO DisposableFinalizers
newDisposableFinalizers = DisposableFinalizers <$> newTMVarIO []

newDisposableFinalizersSTM :: STM DisposableFinalizers
newDisposableFinalizersSTM = DisposableFinalizers <$> newTMVar []

defaultRegisterFinalizer :: DisposableFinalizers -> STM () -> STM Bool
defaultRegisterFinalizer (DisposableFinalizers finalizerVar) finalizer =
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> do
      putTMVar finalizerVar (finalizer : finalizers)
      pure True
    Nothing -> pure False

defaultRunFinalizers :: DisposableFinalizers -> STM ()
defaultRunFinalizers (DisposableFinalizers finalizerVar) = do
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> sequence_ finalizers
    Nothing -> throwM $ userError "defaultRunFinalizers was called multiple times (it must only be run once)"
