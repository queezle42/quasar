{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ExistentialQuantification #-}

module Control.Monad.Limited (
  liftLtd
) where

import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM (STM)
import Control.Monad.Reader
import Prelude
import Data.Kind
import GHC.TypeLits


class Monad m => Retry m where
  retry :: m a

instance Retry STM where
  retry = STM.retry

instance (Monad (t m), MonadTransCaps '[Retry] t, Retry m) => Retry (t m) where
  retry = liftCaps @'[Retry] retry

type Capability = (Type -> Type) -> Constraint

type Ltd :: [Capability] -> (Type -> Type) -> (Type -> Type)
newtype Ltd caps m a = Ltd (m a)
  deriving newtype (Functor, Applicative, Monad)

type MonadTransCaps :: [Capability] -> ((Type -> Type) -> (Type -> Type)) -> Constraint
class MonadTransCaps caps t where
  liftCaps :: (ApplyConstraints caps m, Monad m) => m a -> t m a

instance requiredCaps :<< availableCaps => MonadTransCaps requiredCaps (Ltd availableCaps) where
  liftCaps = Ltd

instance {-# OVERLAPPABLE #-} MonadTrans t => MonadTransCaps caps t where
  liftCaps = lift

-- TODO Rename - liftBaseCaps?
liftLtd :: (MonadLtd base caps m) => Ltd caps base a -> m a
liftLtd (Ltd f) = unsafeLiftBase f


class (Monad base, Monad m, MonadBase base base) => MonadBase base m | m -> base where
  unsafeLiftBase :: base a -> m a

instance MonadBase base base => MonadBase base (Ltd caps base) where
  unsafeLiftBase = Ltd

instance MonadBase STM STM where
  unsafeLiftBase = id

instance (MonadTrans t, MonadBase base m, Monad (t m)) => MonadBase base (t m) where
  unsafeLiftBase = lift . unsafeLiftBase



type LSTM :: [Capability] -> Type -> Type
type LSTM caps = Ltd caps STM


type (:<) :: Capability -> [Capability] -> Constraint
type family cap :< caps where
  cap :< caps = HasCapability cap caps caps

type HasCapability :: Capability -> [Capability] -> [Capability] -> Constraint
type family HasCapability cap caps debugCaps where
  HasCapability c '[] debugCaps = TypeError ('Text "Missing capability " ':<>: 'ShowType c ':<>: 'Text " in " ':<>: 'ShowType debugCaps)
  HasCapability c (c ': _) _ = ()
  HasCapability c (_ ': cs) debugCaps = HasCapability c cs debugCaps

type (:<<) :: [Capability] -> [Capability] -> Constraint
type family needed :<< available where
  '[] :<< _ = ()
  (n ': ns) :<< as = (n :< as, ns :<< as)



type MonadLtd :: (Type -> Type) -> [Capability] -> (Type -> Type) -> Constraint
type family MonadLtd base requiredCaps m where
  MonadLtd base caps m = (MonadBase base m, ApplyConstraints caps m)


type ApplyConstraints :: [Capability] -> (Type -> Type) -> Constraint
type family ApplyConstraints a m :: Constraint where
  ApplyConstraints '[] _ = ()
  ApplyConstraints (cap ': caps) m = (cap m, ApplyConstraints caps m)
