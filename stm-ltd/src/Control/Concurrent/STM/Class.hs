{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Concurrent.STM.Class (
  MonadSTM,
  liftSTM,
  MonadSTM'(..),
  CanBlock,
  CanThrow,
  STM',
  runSTM',
  unsafeLimitSTM,
) where

import Control.Applicative
import Control.Concurrent.STM (STM, TVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad.Catch
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Writer
import Data.Kind (Type, Constraint)
import Prelude

data BlockMode = CanBlock
data ThrowMode = CanThrow

type CanBlock :: BlockMode
type CanBlock = 'CanBlock

type CanThrow :: ThrowMode
type CanThrow = 'CanThrow

type STM' :: BlockMode -> ThrowMode -> Type -> Type
newtype STM' b t a = STM' (STM a)
  deriving newtype (Functor, Applicative, Monad)

instance MonadThrow (STM' b CanThrow) where
  throwM ex = STM' (throwM ex)

instance MonadCatch (STM' b CanThrow) where
  catch = catchSTM

instance Semigroup a => Semigroup (STM' b t a) where
  (<>) = liftA2 (<>)

instance Monoid a => Monoid (STM' b t a) where
  mempty = pure mempty


type MonadSTM' :: BlockMode -> ThrowMode -> (Type -> Type) -> Constraint
class MonadSTM' b t m | m -> b, m -> t where
  liftSTM' :: STM' b t a -> m a


type MonadSTM = MonadSTM' CanBlock CanThrow

liftSTM :: MonadSTM m => STM a -> m a
liftSTM fn = liftSTM' (unsafeLimitSTM fn)


instance MonadSTM' CanBlock CanThrow STM where
  liftSTM' = runSTM'

instance MonadSTM' b t (STM' b t) where
  liftSTM' = id

instance MonadSTM' b t m => MonadSTM' b t (ReaderT r m) where
  liftSTM' = undefined

instance MonadSTM' b t m => MonadSTM' b t (WriterT w m) where
  liftSTM' = undefined


--class MonadRetry m where
--  retry :: m a
--
--instance MonadSTM' CanBlock t m => MonadRetry m where
--  retry = unsafeLimitSTM STM.retry


runSTM' :: STM' b t a -> STM a
runSTM' (STM' fn) = fn



unsafeLimitSTM :: (MonadSTM' b t m) => STM a -> m a
unsafeLimitSTM fn = liftSTM' (STM' fn)


readTVar :: MonadSTM' b t m => TVar a -> m a
readTVar var = unsafeLimitSTM (STM.readTVar var)

retry :: MonadSTM' CanBlock t m => m a
retry = unsafeLimitSTM STM.retry

throwSTM :: (MonadSTM' b CanThrow m, Exception e) => e -> m a
throwSTM = unsafeLimitSTM . STM.throwSTM

catchSTM :: (MonadSTM' b t m, Exception e) => STM' b CanThrow a -> (e -> STM' b t a) -> m a
catchSTM (STM' fx) fn = unsafeLimitSTM $ catch (unsafeLimitSTM fx) (\ex -> runSTM' (fn ex))


--foobar :: STM' CanBlock t ()
--foobar = do
--  var <- unsafeLimitSTM $ STM.newTVar True
--  _x <- readTVar var
--  retry
--
--foobar' :: STM' CanBlock CanThrow ()
--foobar' = do
--  catchSTM (throwM (userError "foobar")) (\(_ :: SomeException) -> traceM "caught")
--  retry
--
--catchphrase :: STM' CanBlock t ()
--catchphrase = catchSTM (throwM (userError "foobar")) (\(_ :: SomeException) -> traceM "caught")
--
--rethrow :: STM' b CanThrow ()
--rethrow = catchSTM (throwM (userError "foobar")) (\(ex :: SomeException) -> throwM ex)
--
--foobar_' :: ReaderT Int (STM' CanBlock CanThrow) ()
--foobar_' = do
--  retry
--
--foobar'' :: STM ()
--foobar'' = do
--  runSTM' retry
--
--foobar''' :: ReaderT Int STM ()
--foobar''' = do
--  _var <- liftSTM (STM.newTVar False)
--  retry
