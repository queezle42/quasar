module Quasar.Disposer.NewDisposable (
  -- * NewDisposable
  NewDisposable(..),
  createNewDisposable,

  unmanagedDisposer,

  swallowDisposer,
  swallowDisposerIO,
  swallowDisposerBy,
  swallowDisposerByIO,

  -- * NewTDisposable
  NewTDisposable(..),
  createNewTDisposable,

  unmanagedTDisposer,

  swallowTDisposer,
  swallowTDisposerIO,
  swallowTDisposerBy,
  swallowTDisposerByIO,
) where

import Quasar.Disposer.Core
import Quasar.MonadQuasar
import Quasar.Exceptions
import Quasar.Future
import Quasar.Prelude
import Control.Exception (fromException)
import Control.Monad.Catch (MonadMask, mask_, catchAll, throwM)

newtype NewDisposable m a = NewDisposable (m (Disposer, a))

instance Functor m => Functor (NewDisposable m) where
  fmap fn (NewDisposable f) = NewDisposable (fn <<$>> f)


createNewDisposable :: Functor m => Disposable a => m a -> NewDisposable m a
createNewDisposable f = NewDisposable do
  r <- f
  pure (getDisposer r, r)


swallowDisposer ::
  (HasCallStack, MonadQuasar m, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  NewDisposable m a -> m a
swallowDisposer f = do
  rm <- askResourceManager
  swallowDisposerBy rm f

swallowDisposerIO ::
  (HasCallStack, MonadQuasar m, MonadIO m, MonadMask m) =>
  NewDisposable m a -> m a
swallowDisposerIO f = do
  rm <- askResourceManager
  swallowDisposerByIO rm f

swallowDisposerBy ::
  (HasCallStack, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  ResourceManager -> NewDisposable m a -> m a
swallowDisposerBy rm f = do
  disposing <- isJust <$> peekFuture (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  (disposer, r) <- unmanagedDisposer f
  catchAllSTMc @NoRetry @'[FailedToAttachResource]
    (attachResource rm disposer)
    \_ex -> throwC mkAlreadyDisposing -- rolls back f
  pure r

swallowDisposerByIO ::
  (HasCallStack, MonadIO m, MonadMask m) =>
  ResourceManager -> NewDisposable m a -> m a
swallowDisposerByIO rm f = do
  disposing <- isJust <$> peekFutureIO (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  mask_ do
    (disposer, r) <- unmanagedDisposer f
    atomically (attachResource rm disposer) `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ disposer
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwC mkAlreadyDisposing
        _ -> throwM ex
    pure r

unmanagedDisposer :: NewDisposable m a -> m (Disposer, a)
unmanagedDisposer (NewDisposable f) = f


-- * NewTDisposable

newtype NewTDisposable m a = NewTDisposable (m (TDisposer, a))

instance Functor m => Functor (NewTDisposable m) where
  fmap fn (NewTDisposable f) = NewTDisposable (fn <<$>> f)


createNewTDisposable :: Functor m => TDisposable a => m a -> NewTDisposable m a
createNewTDisposable f = NewTDisposable do
  r <- f
  pure (getTDisposer r, r)


swallowTDisposer ::
  (HasCallStack, MonadQuasar m, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  NewTDisposable m a -> m a
swallowTDisposer f = do
  rm <- askResourceManager
  swallowTDisposerBy rm f

swallowTDisposerIO ::
  (HasCallStack, MonadQuasar m, MonadIO m, MonadMask m) =>
  NewTDisposable m a -> m a
swallowTDisposerIO f = do
  rm <- askResourceManager
  swallowTDisposerByIO rm f

swallowTDisposerBy ::
  (HasCallStack, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  ResourceManager -> NewTDisposable m a -> m a
swallowTDisposerBy rm f = do
  disposing <- isJust <$> peekFuture (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  (disposer, r) <- unmanagedTDisposer f
  catchAllSTMc @NoRetry @'[FailedToAttachResource]
    (attachResource rm disposer)
    \_ex -> throwC mkAlreadyDisposing -- rolls back f
  pure r

swallowTDisposerByIO ::
  (HasCallStack, MonadIO m, MonadMask m) =>
  ResourceManager -> NewTDisposable m a -> m a
swallowTDisposerByIO rm f = do
  disposing <- isJust <$> peekFutureIO (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  mask_ do
    (disposer, r) <- unmanagedTDisposer f
    atomically (attachResource rm disposer) `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ disposer
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwC mkAlreadyDisposing
        _ -> throwM ex
    pure r

unmanagedTDisposer :: NewTDisposable m a -> m (TDisposer, a)
unmanagedTDisposer (NewTDisposable f) = f
