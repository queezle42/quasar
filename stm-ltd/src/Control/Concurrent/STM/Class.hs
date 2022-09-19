{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Concurrent.STM.Class (
  -- * Monad
  STM,
  atomically,
  MonadSTM,
  liftSTM,

  STM',
  RetryMode(..),
  CanRetry,
  NoRetry,
  ThrowMode(..),
  CanThrow,
  NoThrow,
  MonadSTM'(..),
  runSTM',
  unsafeLimitSTM,

  retry,
  orElse,
  orElse',
  check,
  throwSTM,
  catchSTM,
  catchSTM',

  -- * Unique

  newUniqueSTM,

  -- * TVar
  STM.TVar,
  newTVar,
  newTVarIO,
  readTVar,
  readTVarIO,
  writeTVar,
  modifyTVar,
  modifyTVar',
  stateTVar,
  swapTVar,
  registerDelay,
  mkWeakTVar,

  -- * TMVar
  STM.TMVar,
  newTMVar,
  newEmptyTMVar,
  newTMVarIO,
  newEmptyTMVarIO,
  takeTMVar,
  putTMVar,
  readTMVar,
#if MIN_VERSION_stm(2, 5, 1)
  writeTMVar,
#endif
  tryReadTMVar,
  swapTMVar,
  tryTakeTMVar,
  tryPutTMVar,
  isEmptyTMVar,
  mkWeakTMVar,

  -- * TChan

  -- * TQueue

  -- * TBQueue

  -- * TArray
) where

import Control.Applicative
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.Class.TH
import Control.Monad.Catch
import Control.Monad.Fix (MonadFix)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.RWS (RWST)
import Control.Monad.Trans.Reader (ReaderT)
import Control.Monad.Trans.State (StateT)
import Control.Monad.Trans.Writer (WriterT, execWriterT)
import Data.Kind (Type, Constraint)
import Data.Unique (Unique, newUnique)
import GHC.Conc (unsafeIOToSTM)
import Language.Haskell.TH hiding (Type)
import Prelude


data RetryMode = CanRetry | NoRetry
data ThrowMode = CanThrow | NoThrow

type CanRetry :: RetryMode
type CanRetry = 'CanRetry

type NoRetry :: RetryMode
type NoRetry = 'NoRetry

type CanThrow :: ThrowMode
type CanThrow = 'CanThrow

type NoThrow :: ThrowMode
type NoThrow = 'NoThrow

type STM' :: RetryMode -> ThrowMode -> Type -> Type
newtype STM' r t a = STM' (STM a)
  deriving newtype (Functor, Applicative, Monad, MonadFix)

instance MonadThrow (STM' r CanThrow) where
  throwM ex = STM' (throwM ex)

instance MonadCatch (STM' r CanThrow) where
  catch = catchSTM'

instance Semigroup a => Semigroup (STM' r t a) where
  (<>) = liftA2 (<>)

instance Monoid a => Monoid (STM' r t a) where
  mempty = pure mempty


type MonadSTM' :: RetryMode -> ThrowMode -> (Type -> Type) -> Constraint
class Monad m => MonadSTM' (r :: RetryMode) (t :: ThrowMode) m | m -> r, m -> t where
  liftSTM' :: STM' r t a -> m a


type MonadSTM = MonadSTM' CanRetry CanThrow

liftSTM :: MonadSTM m => STM a -> m a
liftSTM fn = liftSTM' (unsafeLimitSTM fn)


instance MonadSTM' CanRetry CanThrow STM where
  liftSTM' = runSTM'

instance MonadSTM' r t (STM' r t) where
  liftSTM' = id

instance MonadSTM' r t m => MonadSTM' r t (ReaderT rd m) where
  liftSTM' = lift . liftSTM'

instance (MonadSTM' r t m, Monoid w) => MonadSTM' r t (WriterT w m) where
  liftSTM' = lift . liftSTM'

instance MonadSTM' r t m => MonadSTM' r t (StateT w m) where
  liftSTM' = lift . liftSTM'

instance (MonadSTM' r t m, Monoid w) => MonadSTM' r t (RWST rd w s m) where
  liftSTM' = lift . liftSTM'


runSTM' :: STM' r t a -> STM a
runSTM' (STM' fn) = fn


unsafeLimitSTM :: (MonadSTM' r t m) => STM a -> m a
unsafeLimitSTM fn = liftSTM' (STM' fn)


orElse :: MonadSTM m => STM a -> STM a -> m a
orElse fx fy = liftSTM (STM.orElse fx fy)

orElse' :: MonadSTM' r t m => STM' CanRetry t a -> STM' r t a -> m a
orElse' fx fy = unsafeLimitSTM $ STM.orElse (runSTM' fx) (runSTM' fy)

catchSTM :: (MonadSTM m, Exception e) => STM a -> (e -> STM a) -> m a
catchSTM fx fn = liftSTM (STM.catchSTM fx fn)

catchSTM' :: (MonadSTM' r t m, Exception e) => STM' r CanThrow a -> (e -> STM' r t a) -> m a
catchSTM' fx fn = unsafeLimitSTM $ STM.catchSTM (runSTM' fx) \ex -> runSTM' (fn ex)


newUniqueSTM :: MonadSTM' r t m => m Unique
newUniqueSTM = unsafeLimitSTM (unsafeIOToSTM newUnique)


$(mconcat <$> (execWriterT do
  r <- lift $ varT <$> newName "r"
  t <- lift $ varT <$> newName "t"

  -- Declarations that are introduced in this module should have documentation
  tellQs $ mapM mkPragma [
    'liftSTM,
    'liftSTM',
    'runSTM',
    'unsafeLimitSTM,
    'orElse',
    'catchSTM',
    'newUniqueSTM
    ]

  -- Manually implemented wrappers
  tellQs $ mapM (uncurry mkPragmaAndCopyDoc) [
    ('orElse, 'STM.orElse),
    ('catchSTM, 'STM.catchSTM)
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' CanRetry $t|] [|unsafeLimitSTM|]) [
    'STM.retry,
    'STM.check
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r CanThrow|] [|unsafeLimitSTM|]) [
    'STM.throwSTM
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.atomically
    ]

  -- TVar

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r $t|] [|unsafeLimitSTM|]) [
    'STM.newTVar,
    'STM.readTVar,
    'STM.writeTVar,
    'STM.modifyTVar,
    'STM.modifyTVar',
    'STM.stateTVar,
    'STM.swapTVar
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTVarIO,
    'STM.readTVarIO,
    'STM.registerDelay,
    'STM.mkWeakTVar
    ]

  -- TVar

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r $t|] [|unsafeLimitSTM|]) [
    'STM.newTMVar,
    'STM.newEmptyTMVar,
#if MIN_VERSION_stm(2, 5, 1)
    'STM.writeTMVar,
#endif
    'STM.tryReadTMVar,
    'STM.tryTakeTMVar,
    'STM.tryPutTMVar,
    'STM.isEmptyTMVar
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' CanRetry $t|] [|unsafeLimitSTM|]) [
    'STM.takeTMVar,
    'STM.putTMVar,
    'STM.readTMVar,
    'STM.swapTMVar
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTMVarIO,
    'STM.newEmptyTMVarIO,
    'STM.mkWeakTMVar
    ]
  ))
