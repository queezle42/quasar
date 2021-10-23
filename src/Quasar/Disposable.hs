module Quasar.Disposable (
  -- * Disposable
  IsDisposable(..),
  Disposable,
  dispose,
  disposeEventually,
  disposeEventually_,

  newDisposable,
  noDisposable,

  -- * Implementation internals
  DisposeResult(..),
  ResourceManagerResult(..),
  DisposableFinalizers,
  newDisposableFinalizers,
  defaultRegisterFinalizer,
  defaultRunFinalizers,
  awaitResourceManagerResult,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.List.NonEmpty (nonEmpty)
import Data.HashSet (HashSet)
import Data.HashSet qualified as HashSet
import Quasar.Awaitable
import Quasar.Prelude
import Quasar.Utils.Exceptions


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
  beginDispose :: a -> IO DisposeResult
  beginDispose = beginDispose . toDisposable

  isDisposed :: a -> Awaitable ()
  isDisposed = isDisposed . toDisposable

  -- | Finalizers MUST NOT throw exceptions.
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



data ImmediateDisposable = ImmediateDisposable Unique (TMVar (IO ())) DisposableFinalizers (AsyncVar ())

instance IsDisposable ImmediateDisposable where
  beginDispose (ImmediateDisposable key actionVar finalizers resultVar) = do
    -- This is only safe when run in masked state
    atomically (tryTakeTMVar actionVar) >>= mapM_ \action -> do
      result <- try action
      atomically do
        putAsyncVarEitherSTM_ resultVar result
        defaultRunFinalizers finalizers
    -- Await so concurrent `beginDispose` calls don't exit too early
    await resultVar
    pure DisposeResultDisposed

  isDisposed (ImmediateDisposable _ _ _ resultVar) = toAwaitable resultVar `catchAll` \_ -> pure ()

  registerFinalizer (ImmediateDisposable _ _ finalizers _) = defaultRegisterFinalizer finalizers

newImmediateDisposable :: MonadIO m => IO () -> m Disposable
newImmediateDisposable disposeAction = liftIO do
  key <- newUnique
  fmap toDisposable $ ImmediateDisposable key <$> newTMVarIO disposeAction <*> newDisposableFinalizers <*> newAsyncVar



-- | Create a new disposable from an IO action. Is is guaranteed, that the IO action will only be called once (even when
-- `dispose` is called multiple times).
newDisposable :: MonadIO m => IO () -> m Disposable
newDisposable = newImmediateDisposable


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
