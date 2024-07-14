module Quasar.Disposer.Owned (
  -- * Owned Disposer
  -- ** Owned
  Owned(..),
  ownedDisposable,
  fromOwned,
  consumeOwned,
  bracketOwned,

  -- ** Swallow
  swallowDisposer,
  swallowDisposerIO,
  swallowDisposerBy,
  swallowDisposerByIO,


  -- * Owned TDisposer
  -- ** TOwned
  TOwned(..),
  ownedTDisposable,
  fromTOwned,
  consumeTOwned,

  -- ** Swallow
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
import Control.Monad.Catch (MonadMask, mask_, catchAll, throwM, bracket, finally)

data Owned a = Owned Disposer a

instance Functor Owned where
  fmap fn (Owned disposer f) = Owned disposer (fn f)

instance Applicative Owned where
  pure f = Owned mempty f
  liftA2 f (Owned dx x) (Owned dy y) = Owned (dx <> dy) (f x y)

-- Monad instance intentionally left out because of semantic problems.

instance Semigroup a => Semigroup (Owned a) where
  Owned dx x <> Owned dy y = Owned (dx <> dy) (x <> y)

instance Monoid a => Monoid (Owned a) where
  mempty = Owned mempty mempty

ownedDisposable :: Disposable a => a -> Owned a
ownedDisposable f = Owned (getDisposer f) f

fromOwned :: Owned a -> a
fromOwned (Owned _ value) = value

instance Disposable (Owned a) where
  getDisposer (Owned disposer _) = disposer

consumeOwned :: (MonadIO m, MonadMask m) => Owned a -> (a -> m b) -> m b
consumeOwned owned fn =
  finally
    (fn (fromOwned owned))
    (dispose owned)

bracketOwned :: (MonadIO m, MonadMask m) => m (Owned a) -> (a -> m b) -> m b
bracketOwned aquire fn =
  bracket
    aquire
    dispose
    (fn . fromOwned)




data TOwned a = TOwned TDisposer a

instance Disposable (TOwned a) where
  getDisposer (TOwned disposer _) = getDisposer disposer

instance TDisposable (TOwned a) where
  getTDisposer (TOwned disposer _) = disposer

instance Functor TOwned where
  fmap fn (TOwned disposer f) = TOwned disposer (fn f)

instance Applicative TOwned where
  pure f = TOwned mempty f
  liftA2 f (TOwned dx x) (TOwned dy y) = TOwned (dx <> dy) (f x y)

-- Monad instance intentionally left out because of semantic problems.

instance Semigroup a => Semigroup (TOwned a) where
  TOwned dx x <> TOwned dy y = TOwned (dx <> dy) (x <> y)

instance Monoid a => Monoid (TOwned a) where
  mempty = TOwned mempty mempty

ownedTDisposable :: TDisposable a => a -> TOwned a
ownedTDisposable f = TOwned (getTDisposer f) f

fromTOwned :: TOwned a -> a
fromTOwned (TOwned _ value) = value

consumeTOwned :: TOwned a -> (a -> IO b) -> IO b
consumeTOwned owned fn =
  finally
    (fn (fromTOwned owned))
    (dispose owned)



swallowDisposer ::
  (HasCallStack, MonadQuasar m, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  m (Owned a) -> m a
swallowDisposer f = do
  rm <- askResourceManager
  swallowDisposerBy rm f

swallowDisposerIO ::
  (HasCallStack, MonadQuasar m, MonadIO m, MonadMask m) =>
  m (Owned a) -> m a
swallowDisposerIO f = do
  rm <- askResourceManager
  swallowDisposerByIO rm f

swallowDisposerBy ::
  (HasCallStack, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  ResourceManager -> m (Owned a) -> m a
swallowDisposerBy rm f = do
  disposing <- isJust <$> peekFuture (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  Owned disposer r <- f
  catchAllSTMc @NoRetry @'[FailedToAttachResource]
    (attachResource rm disposer)
    \_ex -> throwC mkAlreadyDisposing -- rolls back f
  pure r

swallowDisposerByIO ::
  (HasCallStack, MonadIO m, MonadMask m) =>
  ResourceManager -> m (Owned a) -> m a
swallowDisposerByIO rm f = do
  disposing <- isJust <$> peekFutureIO (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  mask_ do
    Owned disposer r <- f
    atomically (attachResource rm disposer) `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ disposer
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwC mkAlreadyDisposing
        _ -> throwM ex
    pure r



swallowTDisposer ::
  (HasCallStack, MonadQuasar m, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  m (TOwned a) -> m a
swallowTDisposer f = do
  rm <- askResourceManager
  swallowTDisposerBy rm f

swallowTDisposerIO ::
  (HasCallStack, MonadQuasar m, MonadIO m, MonadMask m) =>
  m (TOwned a) -> m a
swallowTDisposerIO f = do
  rm <- askResourceManager
  swallowTDisposerByIO rm f

swallowTDisposerBy ::
  (HasCallStack, MonadSTMc NoRetry '[AlreadyDisposing] m) =>
  ResourceManager -> m (TOwned a) -> m a
swallowTDisposerBy rm f = do
  disposing <- isJust <$> peekFuture (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  TOwned disposer r <- f
  catchAllSTMc @NoRetry @'[FailedToAttachResource]
    (attachResource rm disposer)
    \_ex -> throwC mkAlreadyDisposing -- rolls back f
  pure r

swallowTDisposerByIO ::
  (HasCallStack, MonadIO m, MonadMask m) =>
  ResourceManager -> m (TOwned a) -> m a
swallowTDisposerByIO rm f = do
  disposing <- isJust <$> peekFutureIO (isDisposing rm)
  when disposing $ throwC mkAlreadyDisposing

  mask_ do
    TOwned disposer r <- f
    atomically (attachResource rm disposer) `catchAll` \ex -> do
      -- When the resource cannot be registered (because resource manager is now disposing), destroy it to prevent leaks
      atomically $ disposeEventually_ disposer
      case ex of
        (fromException -> Just FailedToAttachResource) -> throwC mkAlreadyDisposing
        _ -> throwM ex
    pure r
