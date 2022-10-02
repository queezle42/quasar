{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Concurrent.STM.Class (
  -- * Monad
  -- ** STM
  STM,
  atomically,

  -- ** MonadSTM
  MonadSTM,
  liftSTM,

  -- ** STM'
  STM',
  runSTM',
  -- *** Capabilities
  RetryMode(..),
  CanRetry,
  NoRetry,
  ThrowMode(..),
  CanThrow,
  NoThrow,

  -- ** MonadSTM'
  MonadSTM'(..),
  noRetry,
  noThrow,
  unsafeLimitSTM,

  -- ** Retry
  retry,
  orElse,
  orElse',
  check,

  -- ** Throw
  throwSTM,
  catchSTM,
  catchSTM',
  catchAllSTM',

  -- * Unique

  Unique,
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
  STM.TChan,
  newTChan,
  newTChanIO,
  newBroadcastTChan,
  newBroadcastTChanIO,
  dupTChan,
  cloneTChan,
  readTChan,
  tryReadTChan,
  peekTChan,
  tryPeekTChan,
  writeTChan,
  unGetTChan,
  isEmptyTChan,

  -- * TQueue
  STM.TQueue,
  newTQueue,
  newTQueueIO,
  readTQueue,
  tryReadTQueue,
  flushTQueue,
  peekTQueue,
  tryPeekTQueue,
  writeTQueue,
  unGetTQueue,
  isEmptyTQueue,

  -- * TBQueue
  STM.TBQueue,
  newTBQueue,
  newTBQueueIO,
  readTBQueue,
  tryReadTBQueue,
  flushTBQueue,
  peekTBQueue,
  tryPeekTBQueue,
  writeTBQueue,
  unGetTBQueue,
  lengthTBQueue,
  isEmptyTBQueue,
  isFullTBQueue,

  -- * TArray
  STM.TArray,
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
import Data.Array.MArray qualified as MArray
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
-- | A monad supporting atomic memory transactions. The type variables @r@ and
-- @t@ denote the capabilities to retry and throw respectively.
newtype STM' (r :: RetryMode) (t :: ThrowMode) a = STM' (STM a)
  deriving newtype (Functor, Applicative, Monad, MonadFix)

-- | While the MArray-instance does not require a `CanThrow`-modifier, please
-- please note that `MArray.readArray` and `MArray.writeArray` (the primary
-- interface for MArray) are partial.
deriving newtype instance MArray.MArray STM.TArray e (STM' r t)

instance MonadThrow (STM' r CanThrow) where
  throwM ex = STM' (throwM ex)
  {-# INLINABLE throwM #-}

instance MonadCatch (STM' r CanThrow) where
  catch = catchSTM'
  {-# INLINABLE catch #-}

instance Semigroup a => Semigroup (STM' r t a) where
  (<>) = liftA2 (<>)
  {-# INLINABLE (<>) #-}

instance Monoid a => Monoid (STM' r t a) where
  mempty = pure mempty
  {-# INLINABLE mempty #-}


type MonadSTM' :: RetryMode -> ThrowMode -> (Type -> Type) -> Constraint
-- | Monad in which 'STM'' computations can be embedded. The type variables @r@
-- and @t@ denote the capabilities to retry and throw respectively.
class Monad m => MonadSTM' (r :: RetryMode) (t :: ThrowMode) m | m -> r, m -> t where
  -- | Lift a computation from the 'STM'' monad.
  liftSTM' :: STM' r t a -> m a


-- | Monad in which 'STM' and 'STM'' computations can be embedded.
type MonadSTM = MonadSTM' CanRetry CanThrow

-- | Lift a computation from the 'STM' monad.
liftSTM :: MonadSTM m => STM a -> m a
liftSTM fn = liftSTM' (STM' fn)
{-# INLINABLE liftSTM #-}


instance MonadSTM' CanRetry CanThrow STM where
  liftSTM' (STM' f) = f
  {-# INLINE CONLIKE liftSTM' #-}

instance MonadSTM' r t (STM' r t) where
  liftSTM' = id
  {-# INLINE CONLIKE liftSTM' #-}

instance MonadSTM' r t m => MonadSTM' r t (ReaderT rd m) where
  liftSTM' = lift . liftSTM'
  {-# INLINABLE liftSTM' #-}

instance (MonadSTM' r t m, Monoid w) => MonadSTM' r t (WriterT w m) where
  liftSTM' = lift . liftSTM'
  {-# INLINABLE liftSTM' #-}

instance MonadSTM' r t m => MonadSTM' r t (StateT w m) where
  liftSTM' = lift . liftSTM'
  {-# INLINABLE liftSTM' #-}

instance (MonadSTM' r t m, Monoid w) => MonadSTM' r t (RWST rd w s m) where
  liftSTM' = lift . liftSTM'
  {-# INLINABLE liftSTM' #-}


runSTM' :: MonadSTM m => STM' r t a -> m a
runSTM' (STM' f) = liftSTM f
{-# INLINABLE runSTM' #-}

noRetry :: MonadSTM' r t m => STM' NoRetry t a -> m a
noRetry = unsafeLimitSTM . runSTM'
{-# INLINABLE noRetry #-}

noThrow :: MonadSTM' r t m => STM' r NoThrow a -> m a
noThrow = unsafeLimitSTM . runSTM'
{-# INLINABLE noThrow #-}


unsafeLimitSTM :: (MonadSTM' r t m) => STM a -> m a
unsafeLimitSTM fn = liftSTM' (STM' fn)
{-# INLINABLE unsafeLimitSTM #-}


-- Documentation is copied via template-haskell
orElse :: MonadSTM m => STM a -> STM a -> m a
orElse fx fy = liftSTM (STM.orElse fx fy)
{-# INLINABLE orElse #-}

orElse' :: MonadSTM' r t m => STM' CanRetry t a -> STM' r t a -> m a
orElse' fx fy = unsafeLimitSTM $ STM.orElse (runSTM' fx) (runSTM' fy)
{-# INLINABLE orElse' #-}

-- Documentation is copied via template-haskell
catchSTM :: (MonadSTM m, Exception e) => STM a -> (e -> STM a) -> m a
catchSTM fx fn = liftSTM (STM.catchSTM fx fn)
{-# INLINABLE catchSTM #-}

catchSTM' :: (MonadSTM' r CanThrow m, Exception e) => STM' r CanThrow a -> (e -> STM' r CanThrow a) -> m a
catchSTM' fx fn = unsafeLimitSTM $ STM.catchSTM (runSTM' fx) \ex -> runSTM' (fn ex)
{-# INLINABLE catchSTM' #-}

catchAllSTM' :: (MonadSTM' r t m) => STM' r CanThrow a -> (SomeException -> STM' r t a) -> m a
catchAllSTM' fx fn = unsafeLimitSTM $ STM.catchSTM (runSTM' fx) \ex -> runSTM' (fn ex)
{-# INLINABLE catchAllSTM' #-}

-- | Creates a new object of type `Unique`. The value returned will not compare
-- equal to any other value of type 'Unique' returned by previous calls to
-- `newUnique` and `newUniqueSTM`. There is no limit on the number of times
-- `newUniqueSTM` may be called.
newUniqueSTM :: MonadSTM' r t m => m Unique
newUniqueSTM = unsafeLimitSTM (unsafeIOToSTM newUnique)
{-# INLINABLE newUniqueSTM #-}


$(mconcat <$> (execWriterT do
  r <- lift $ varT <$> newName "r"
  t <- lift $ varT <$> newName "t"

  -- Manually implemented wrappers
  lift $ mapM_ (uncurry copyDoc) [
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

  -- TChan

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r $t|] [|unsafeLimitSTM|]) [
    'STM.newTChan,
    'STM.newBroadcastTChan,
    'STM.dupTChan,
    'STM.cloneTChan,
    'STM.tryReadTChan,
    'STM.tryPeekTChan,
    'STM.writeTChan,
    'STM.unGetTChan,
    'STM.isEmptyTChan
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' CanRetry $t|] [|unsafeLimitSTM|]) [
    'STM.readTChan,
    'STM.peekTChan
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTChanIO,
    'STM.newBroadcastTChanIO
    ]

  -- TQueue

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r $t|] [|unsafeLimitSTM|]) [
    'STM.newTQueue,
    'STM.tryReadTQueue,
    'STM.flushTQueue,
    'STM.tryPeekTQueue,
    'STM.writeTQueue,
    'STM.unGetTQueue,
    'STM.isEmptyTQueue
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' CanRetry $t|] [|unsafeLimitSTM|]) [
    'STM.readTQueue,
    'STM.peekTQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTQueueIO
    ]

  -- TBQueue

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' $r $t|] [|unsafeLimitSTM|]) [
    'STM.newTBQueue,
    'STM.tryReadTBQueue,
    'STM.flushTBQueue,
    'STM.tryPeekTBQueue,
    'STM.lengthTBQueue,
    'STM.isEmptyTBQueue,
    'STM.isFullTBQueue
    ]

  tellQs $ mapM (mkMonadClassWrapper [t|MonadSTM' CanRetry $t|] [|unsafeLimitSTM|]) [
    'STM.readTBQueue,
    'STM.peekTBQueue,
    'STM.writeTBQueue,
    'STM.unGetTBQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTBQueueIO
    ]
  ))
