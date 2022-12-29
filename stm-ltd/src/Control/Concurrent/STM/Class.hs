{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Concurrent.STM.Class (
  -- * Monad
  -- ** STM
  STM,
  STMBaseCapabilities,
  atomically,

  -- ** MonadSTM
  MonadSTM,
  liftSTM,

  -- ** STMc
  STMc,
  STMcCapabilities,
  atomicallyC,

  -- *** Limiting capabilities
  -- TODO

  -- ** MonadSTM'
  MonadSTMc,
  liftSTMc,
  (:<),
  (:<<),

  -- ** Retry
  Retry(..),
  orElse,
  orElseC,
  check,

  -- ** Throw
  throwSTM,
  Throw(..),
  ThrowAny,
  throwAny,
  catchSTM,
  catchSTMc,
  catchAllSTMc,
  trySTMc,
  tryAllSTMc,

  -- * Control.Monad.Capability reexports
  UnsafeLiftBase,

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
import Control.Monad (MonadPlus)
import Control.Monad.Capability
import Control.Monad.Catch
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class
import Control.Monad.Trans.Class (lift, MonadTrans)
import Control.Monad.Trans.Writer (execWriterT)
import Data.Array.MArray qualified as MArray
import Data.Kind (Type, Constraint)
import Data.Unique (Unique, newUnique)
import GHC.Conc (unsafeIOToSTM)
import Language.Haskell.TH hiding (Type)
import Prelude


type STMBaseCapabilities = '[Retry, ThrowAny]


type STMc :: [Capability] -> Type -> Type
newtype STMc caps a = STMc (STM a)
  deriving newtype (Functor, Applicative, Monad, MonadFix)

instance (c :< caps, STMcCapabilities caps) => HasCapability c (STMc caps)

instance STMcCapabilities caps => UnsafeLiftBase (STMc caps) where
  type UnsafeBaseMonad (STMc caps) = STM
  unsafeLiftBase = STMc


instance (ThrowAny (STMc caps), STMcCapabilities caps) => MonadThrow (STMc caps) where
  throwM = throwAny

instance (ThrowAny (STMc caps), STMcCapabilities caps) => MonadCatch (STMc caps) where
  catch ft fc = STMc (STM.catchSTM (runSTMc ft) (runSTMc . fc))

instance Semigroup a => Semigroup (STMc caps a) where
  (<>) = liftA2 (<>)
  {-# INLINABLE (<>) #-}

instance Monoid a => Monoid (STMc caps a) where
  mempty = pure mempty
  {-# INLINABLE mempty #-}

-- | While the MArray-instance does not require a `CanThrow`-modifier, please
-- please note that `MArray.readArray` and `MArray.writeArray` (the primary
-- interface for MArray) are partial.
deriving newtype instance MArray.MArray STM.TArray e (STMc caps)

deriving newtype instance Retry (STMc caps) => Alternative (STMc caps)

deriving newtype instance Retry (STMc caps) => MonadPlus (STMc caps)


type MonadSTMc :: [Capability] -> (Type -> Type) -> Constraint
type MonadSTMc caps m =
  (
    RequireCapabilities caps m,
    STMcCapabilities caps,
    UnsafeLiftBase m,
    UnsafeBaseMonad m ~ STM
  )


liftSTMc :: MonadSTMc caps m => STMc caps a -> m a
liftSTMc f = unsafeLiftSTM (runSTMc f)

unsafeLiftSTM :: (UnsafeLiftBase m, UnsafeBaseMonad m ~ STM) => STM a -> m a
unsafeLiftSTM = unsafeLiftBase

-- | Monad in which 'STM' and 'STMc' computations can be embedded.
type MonadSTM m = MonadSTMc STMBaseCapabilities m

-- | Lift a computation from the 'STM' monad.
liftSTM :: MonadSTM m => STM a -> m a
liftSTM = unsafeLiftSTM
{-# INLINABLE liftSTM #-}


runSTMc :: STMcCapabilities caps => STMc caps a -> STM a
runSTMc (STMc f) = f


type STMcCapabilities caps = RequireCapabilities caps (STMc caps)


catchSTMc ::
  forall caps e m a. (
    Exception e,
    MonadSTMc (caps :- Throw e) m,
    STMcCapabilities caps
  ) =>
  STMc caps a -> (e -> m a) -> m a

catchSTMc ft fc = trySTMc ft >>= either fc pure
{-# INLINABLE catchSTMc #-}

catchAllSTMc ::
  forall caps m a. (
    MonadSTMc (caps :- ThrowAny) m,
    STMcCapabilities caps
  ) =>
  STMc caps a -> (SomeException -> m a) -> m a

catchAllSTMc ft fc = tryAllSTMc ft >>= either fc pure
{-# INLINABLE catchAllSTMc #-}


trySTMc ::
  forall caps e m a. (
    Exception e,
    MonadSTMc (caps :- Throw e) m,
    STMcCapabilities caps
  ) =>
  STMc caps a -> m (Either e a)
trySTMc f = unsafeLiftSTM (try (runSTMc f))
{-# INLINABLE trySTMc #-}

tryAllSTMc ::
  forall caps m a. (
    MonadSTMc (caps :- ThrowAny) m,
    STMcCapabilities caps
  ) =>
  STMc caps a -> m (Either SomeException a)
tryAllSTMc f = unsafeLiftSTM (try (runSTMc f))
{-# INLINABLE tryAllSTMc #-}


class Monad m => Retry m where
  retry :: m a

instance Retry STM where
  retry = STM.retry

instance HasCapability Retry STM

instance Retry :< caps => Retry (STMc caps) where
  retry = STMc retry

instance (Retry m, MonadTrans t, Monad (t m)) => Retry (t m) where
  retry = lift retry


orElseC ::
  forall caps m a. (
    MonadSTMc (caps :- Retry) m,
    STMcCapabilities caps
  ) =>
  STMc caps a -> m a -> m a
orElseC fx fy =
  unsafeLiftSTM (STM.orElse (Just <$> runSTMc fx) (pure Nothing)) >>= \case
    Just r -> pure r
    Nothing -> fy
{-# INLINABLE orElseC #-}



atomicallyC :: MonadIO m => STMc STMBaseCapabilities a -> m a
atomicallyC = liftIO . STM.atomically . runSTMc
{-# INLINABLE atomicallyC #-}



-- | Creates a new object of type `Unique`. The value returned will not compare
-- equal to any other value of type 'Unique' returned by previous calls to
-- `newUnique` and `newUniqueSTM`. There is no limit on the number of times
-- `newUniqueSTM` may be called.
newUniqueSTM :: MonadSTMc '[] m => m Unique
newUniqueSTM = liftSTMc @'[] $ unsafeLiftSTM (unsafeIOToSTM newUnique)
{-# INLINABLE newUniqueSTM #-}


$(mconcat <$> (execWriterT do
  let
    mkMonadSTMcConstraint capTs mT = [t|MonadSTMc $(promotedList capTs) $mT|]

    mkMonadSTMcWrapper capTs = mkMonadClassWrapper (mkMonadSTMcConstraint capTs) [|unsafeLiftSTM|]
    mkMonadSTMWrapper = mkMonadClassWrapper (\mT -> [t|MonadSTM $mT|]) [|liftSTM|]

    promotedList :: [TypeQ] -> TypeQ
    promotedList [] = promotedNilT
    promotedList (x:xs) = [t|$promotedConsT $x $(promotedList xs)|]

  tellQs $ mapM (mkMonadSTMcWrapper [[t|Retry|]]) [
    --'STM.retry,
    'STM.check
    ]

  --tellQs $ mapM (mkMonadClassWrapper (\m -> [t|MonadSTMc '[ThrowAny] $m|]) [|unsafeLiftSTM|]) [
  tellQs $ mapM (mkMonadSTMcWrapper [[t|ThrowAny|]]) [
    'STM.throwSTM
    ]

  tellQs $ mapM mkMonadSTMWrapper [
    'STM.orElse,
    'STM.catchSTM
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.atomically
    ]

  -- TVar

  tellQs $ mapM (mkMonadSTMcWrapper []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [[t|Retry|]]) [
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

  tellQs $ mapM (mkMonadSTMcWrapper []) [
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

  tellQs $ mapM (mkMonadSTMcWrapper [[t|Retry|]]) [
    'STM.readTChan,
    'STM.peekTChan
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTChanIO,
    'STM.newBroadcastTChanIO
    ]

  -- TQueue

  tellQs $ mapM (mkMonadSTMcWrapper []) [
    'STM.newTQueue,
    'STM.tryReadTQueue,
    'STM.flushTQueue,
    'STM.tryPeekTQueue,
    'STM.writeTQueue,
    'STM.unGetTQueue,
    'STM.isEmptyTQueue
    ]

  tellQs $ mapM (mkMonadSTMcWrapper [[t|Retry|]]) [
    'STM.readTQueue,
    'STM.peekTQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTQueueIO
    ]

  -- TBQueue

  tellQs $ mapM (mkMonadSTMcWrapper []) [
    'STM.newTBQueue,
    'STM.tryReadTBQueue,
    'STM.flushTBQueue,
    'STM.tryPeekTBQueue,
    'STM.lengthTBQueue,
    'STM.isEmptyTBQueue,
    'STM.isFullTBQueue
    ]

  tellQs $ mapM (mkMonadSTMcWrapper [[t|Retry|]]) [
    'STM.readTBQueue,
    'STM.peekTBQueue,
    'STM.writeTBQueue,
    'STM.unGetTBQueue
    ]

  tellQs $ mapM mkMonadIOWrapper [
    'STM.newTBQueueIO
    ]
  ))


#if !MIN_VERSION_stm(2, 5, 1)

-- | Non-blocking write of a new value to a 'TMVar'
-- Puts if empty. Replaces if populated.
writeTMVar :: MonadSTMc '[] m => STM.TMVar a -> a -> m ()
writeTMVar t new = unsafeLiftSTM $ tryTakeTMVar t >> putTMVar t new

#endif
