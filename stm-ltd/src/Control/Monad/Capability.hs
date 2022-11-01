{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Control.Monad.Capability (
  Capability,
  (:<),
  (:<<),
  (:++),
  (:-),
  Throw(..),
  ThrowAny,
  throwAny,
  CapabilityMonad(..),
  IsCapability,
  RequireCapabilities,
) where

import Control.Monad.Catch
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM (STM)
import Control.Monad.Trans.Class
import Prelude
import Data.Kind

type Capability = (Type -> Type) -> Constraint

type (:<) :: k -> [k] -> Constraint
type family a :< b where
  c :< (c ': _) = ()
  Throw _ :< (ThrowAny ': _) = ()
  c :< (_ ': cs) = c :< cs

type (:<<) :: [k] -> [k] -> Constraint
type family a :<< b where
  '[] :<< _ = ()
  (n ': ns) :<< as = (n :< as, ns :<< as)

-- | Concatenate two type-level lists.
type (:++) :: [k] -> [k] -> [k]
type family a :++ b where
  '[] :++ rs = rs
  (l ': ls) :++ rs = l ': (ls :++ rs)

-- | Remove an element from a type-level list.
type (:-) :: [k] -> k -> [k]
type family a :- b where
  '[] :- _ = '[]
  (Throw _ ': xs) :- ThrowAny = xs :- ThrowAny
  (r ': xs) :- r = xs :- r
  (x ': xs) :- r = x ': (xs :- r)



class Monad m => Throw e m where
  throwC :: Exception e => e -> m a

instance Throw e STM where
  throwC = STM.throwSTM

instance (Throw e m, MonadTrans t, Monad (t m)) => Throw e (t m) where
  throwC = lift . throwC

type ThrowAny = Throw SomeException

throwAny :: (Exception e, ThrowAny m) => e -> m a
throwAny = throwC . toException


type IsCapability :: Capability -> (Type -> Type) -> Constraint
class (c m, forall t. (MonadTrans t, Monad (t m)) => (c (t m))) => IsCapability c m

type RequireCapabilities :: [Capability] -> (Type -> Type) -> Constraint
type family RequireCapabilities caps m where
  RequireCapabilities '[] _ = ()
  RequireCapabilities (c ': cs) m = (IsCapability c m, RequireCapabilities cs m)

type CapabilityMonad :: (Type -> Type) -> Constraint
class (Monad m, RequireCapabilities (Caps m) (BaseMonad m)) => CapabilityMonad m where
  type Caps m :: [Capability]
  type BaseMonad m :: (Type -> Type)
  liftBaseC :: BaseMonad m a -> m a

instance (MonadTrans t, CapabilityMonad m, Monad (t m)) => CapabilityMonad (t m) where
  type Caps (t m) = Caps m
  type BaseMonad (t m) = BaseMonad m
  liftBaseC = lift . liftBaseC
