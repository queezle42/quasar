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

  -- ** STMc
  STMc,
  atomicallyC,

  -- ** MonadSTMc
  MonadSTMc,
  MonadSTMcBase(..),
  liftSTMc,
  (:<),
  (:<<),
  (:-),
  (:--),

  -- ** Retry
  MonadRetry(..),
  CanRetry,
  Retry,
  NoRetry,
  orElse,
  orElseC,
  orElseNothing,
  check,

  -- ** Throw
  throwSTM,
  catchSTM,
  catchSTMc,
  catchAllSTMc,
  handleSTMc,
  handleAllSTMc,
  trySTMc,
  tryAllSTMc,
  tryExSTMc,

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
  writeTMVar,
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
import Control.Exception (IOException)
import Control.Exception.Ex
import Control.Monad (MonadPlus)
import Control.Monad.Catch
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class
import Control.Monad.Trans.Class (lift, MonadTrans)
import Control.Monad.Trans.Writer (execWriterT)
import Data.Array.MArray qualified as MArray
import Data.Bifunctor qualified as Bifunctor
import Data.Kind (Type, Constraint)
import Data.Unique (Unique, newUnique)
import GHC.Conc (unsafeIOToSTM)
import Language.Haskell.TH hiding (Type)
import Prelude
import Data.Type.Equality
import Data.Type.Bool


class Monad m => MonadRetry m where
  retry :: m a

instance MonadRetry STM where
  retry = STM.retry

instance MonadRetry (STMc Retry exceptions) where
  retry = unsafeLiftSTM STM.retry

instance (MonadRetry m, Monad (t m), MonadTrans t) => MonadRetry (t m) where
  retry = lift retry


-- TODO use TypeData in a future GHC (currently planned for GHC 9.6.1)
data CanRetry = Retry | NoRetry
type Retry = 'Retry
type NoRetry = 'NoRetry


type role STMc phantom phantom _
type STMc :: CanRetry -> [Type] -> Type -> Type
newtype STMc canRetry exceptions a = STMc (STM a)
  deriving newtype (Functor, Applicative, Monad, MonadFix)

instance SomeException :< exceptions => MonadThrow (STMc canRetry exceptions) where
  throwM = STMc . STM.throwSTM

instance SomeException :< exceptions => MonadCatch (STMc canRetry exceptions) where
  catch ft fc = STMc (STM.catchSTM (runSTMc ft) (runSTMc . fc))

instance IOException :< exceptions => MonadFail (STMc canRetry exceptions) where
  fail = throwSTM . userError

instance Semigroup a => Semigroup (STMc canRetry exceptions a) where
  (<>) = liftA2 (<>)
  {-# INLINABLE (<>) #-}

instance Monoid a => Monoid (STMc canRetry exceptions a) where
  mempty = pure mempty
  {-# INLINABLE mempty #-}

-- | While the MArray-instance does not require a `CanThrow`-modifier, please
-- please note that `MArray.readArray` and `MArray.writeArray` (the primary
-- interface for MArray) are partial.
deriving newtype instance MArray.MArray STM.TArray e (STMc canRetry exceptions)

deriving newtype instance Alternative (STMc Retry exceptions)

deriving newtype instance MonadPlus (STMc Retry exceptions)

instance (Exception e, e :< exceptions) => Throw e (STMc canRetry exceptions) where
  throwC = STMc . STM.throwSTM

instance ThrowEx (STMc canRetry exceptions) where
  unsafeThrowEx = STMc . throwM


type MonadSTMcBase :: (Type -> Type) -> Constraint
class ThrowEx m => MonadSTMcBase m where
  unsafeLiftSTM :: STM a -> m a

instance MonadSTMcBase STM where
  unsafeLiftSTM = id

instance MonadSTMcBase (STMc canRetry exceptions) where
  unsafeLiftSTM = STMc

instance (Monad (t m), MonadTrans t, MonadSTMcBase m) => MonadSTMcBase (t m) where
  unsafeLiftSTM = lift . unsafeLiftSTM


type MonadSTMc :: CanRetry -> [Type] -> (Type -> Type) -> Constraint
type MonadSTMc canRetry exceptions m = (If (canRetry == Retry) (MonadRetry m) (() :: Constraint), MonadSTMcBase m, ThrowForAll exceptions m)


liftSTMc ::
  forall canRetry exceptions m a.
  MonadSTMc canRetry exceptions m =>
  STMc canRetry exceptions a -> m a
liftSTMc f = unsafeLiftSTM (runSTMc f)

-- | Monad in which 'STM' and 'STMc' computations can be embedded.
type MonadSTM m = MonadSTMc Retry '[SomeException] m

-- | Lift a computation from the 'STM' monad.
liftSTM :: MonadSTM m => STM a -> m a
liftSTM = unsafeLiftSTM
{-# INLINABLE liftSTM #-}


runSTMc :: STMc canRetry exceptions a -> STM a
runSTMc (STMc f) = f


throwSTM :: forall e m a. (Exception e, MonadSTMc NoRetry '[e] m) => e -> m a
throwSTM = unsafeLiftSTM . STM.throwSTM

catchSTMc ::
  forall canRetry exceptions e m a. (
    Exception e,
    MonadSTMc canRetry (exceptions :- e) m
  ) =>
  STMc canRetry exceptions a -> (e -> m a) -> m a

catchSTMc ft fc = trySTMc ft >>= either fc pure
{-# INLINABLE catchSTMc #-}

catchAllSTMc ::
  forall canRetry exceptions m a. (
    MonadSTMc canRetry '[] m
  ) =>
  STMc canRetry exceptions a -> (SomeException -> m a) -> m a

catchAllSTMc ft fc = tryAllSTMc ft >>= either fc pure
{-# INLINABLE catchAllSTMc #-}


handleSTMc ::
  forall canRetry exceptions e m a. (
    Exception e,
    MonadSTMc canRetry (exceptions :- e) m
  ) =>
  (e -> m a) -> STMc canRetry exceptions a -> m a

handleSTMc = flip catchSTMc
{-# INLINABLE handleSTMc #-}

handleAllSTMc ::
  forall canRetry exceptions m a. (
    MonadSTMc canRetry '[] m
  ) =>
  (SomeException -> m a) -> STMc canRetry exceptions a -> m a

handleAllSTMc = flip catchAllSTMc
{-# INLINABLE handleAllSTMc #-}


trySTMc ::
  forall canRetry exceptions e m a. (
    Exception e,
    MonadSTMc canRetry (exceptions :- e) m
  ) =>
  STMc canRetry exceptions a -> m (Either e a)
trySTMc f = unsafeLiftSTM (try (runSTMc f))
{-# INLINABLE trySTMc #-}

tryAllSTMc ::
  forall canRetry exceptions m a. (
    MonadSTMc canRetry '[] m
  ) =>
  STMc canRetry exceptions a -> m (Either SomeException a)
tryAllSTMc f = unsafeLiftSTM (try (runSTMc f))
{-# INLINABLE tryAllSTMc #-}

tryExSTMc ::
  forall canRetry exceptions m a. (
    MonadSTMc canRetry '[] m
  ) =>
  STMc canRetry exceptions a -> m (Either (Ex exceptions) a)
tryExSTMc f = unsafeLiftSTM (Bifunctor.first unsafeToEx <$> try (runSTMc f))
{-# INLINABLE tryExSTMc #-}

orElseC ::
  forall exceptions m a. (MonadSTMc NoRetry exceptions m) =>
  STMc Retry exceptions a -> m a -> m a
orElseC fx fy =
  orElseNothing fx >>= \case
    Just r -> pure r
    Nothing -> fy
{-# INLINABLE orElseC #-}

orElseNothing ::
  forall exceptions m a. (MonadSTMc NoRetry exceptions m) =>
  STMc Retry exceptions a -> m (Maybe a)
orElseNothing fx = unsafeLiftSTM (STM.orElse (Just <$> runSTMc fx) (pure Nothing))
{-# INLINABLE orElseNothing #-}


atomicallyC :: MonadIO m => STMc canRetry exceptions a -> m a
atomicallyC = liftIO . STM.atomically . runSTMc
{-# INLINABLE atomicallyC #-}



-- | Creates a new object of type `Unique`. The value returned will not compare
-- equal to any other value of type 'Unique' returned by previous calls to
-- `newUnique` and `newUniqueSTM`. There is no limit on the number of times
-- `newUniqueSTM` may be called.
newUniqueSTM :: MonadSTMc NoRetry '[] m => m Unique
newUniqueSTM = unsafeLiftSTM (unsafeIOToSTM newUnique)
{-# INLINABLE newUniqueSTM #-}


$(mconcat <$> execWriterT do
  let
    mkMonadSTMcConstraint canRetry exceptionTs mT =
      [t|MonadSTMc $canRetry $(promotedList exceptionTs) $mT|]

    mkMonadSTMcWrapper canRetry exceptionTs =
      mkMonadClassWrapper
        (mkMonadSTMcConstraint canRetry exceptionTs)
        [|unsafeLiftSTM|]

    mkMonadSTMWrapper =
      mkMonadClassWrapper (\mT -> [t|MonadSTM $mT|]) [|liftSTM|]

    promotedList :: [TypeQ] -> TypeQ
    promotedList [] = promotedNilT
    promotedList (x:xs) = [t|$promotedConsT $x $(promotedList xs)|]

  tellQs $ mapM (mkMonadSTMcWrapper [t|Retry|] []) [
    --'STM.retry,
    'STM.check
    ]

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] [[t|SomeException|]]) [
    --'STM.throwSTM
    ]

  tellQs $ mapM mkMonadSTMWrapper [
    'STM.orElse,
    'STM.catchSTM
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.atomically
    ]

  -- TVar

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [t|Retry|] []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [t|Retry|] []) [
    'STM.readTChan,
    'STM.peekTChan
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTChanIO,
    'STM.newBroadcastTChanIO
    ]

  -- TQueue

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] []) [
    'STM.newTQueue,
    'STM.tryReadTQueue,
    'STM.flushTQueue,
    'STM.tryPeekTQueue,
    'STM.writeTQueue,
    'STM.unGetTQueue,
    'STM.isEmptyTQueue
    ]

  tellQs $ mapM (mkMonadSTMcWrapper [t|Retry|] []) [
    'STM.readTQueue,
    'STM.peekTQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTQueueIO
    ]

  -- TBQueue

  tellQs $ mapM (mkMonadSTMcWrapper [t|NoRetry|] []) [
    'STM.newTBQueue,
    'STM.tryReadTBQueue,
    'STM.flushTBQueue,
    'STM.tryPeekTBQueue,
    'STM.lengthTBQueue,
    'STM.isEmptyTBQueue,
    'STM.isFullTBQueue
    ]

  tellQs $ mapM (mkMonadSTMcWrapper [t|Retry|] []) [
    'STM.readTBQueue,
    'STM.peekTBQueue,
    'STM.writeTBQueue,
    'STM.unGetTBQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTBQueueIO
    ]
  )


#if !MIN_VERSION_stm(2, 5, 1)

-- | Non-blocking write of a new value to a 'TMVar'
-- Puts if empty. Replaces if populated.
writeTMVar :: MonadSTMc NoRetry '[] m => STM.TMVar a -> a -> m ()
writeTMVar t new = unsafeLiftSTM (tryTakeTMVar t >> putTMVar t new)

#endif
