{-# LANGUAGE UndecidableInstances #-}

module Control.Monad.Capability (
  Capability,
  (:<),
  (:<<),
  (:++),
  (:-),
  UnsafeLiftBase(..),
  HasCapability,
  RequireCapabilities,

  Throw(..),
  ThrowAny(..),
) where

import Control.Monad.Catch
import Control.Concurrent.STM (STM)
import Control.Monad.Trans.Class
import Prelude
import Data.Kind

type Capability = (Type -> Type) -> Constraint

-- | Constraint to assert the existence of a capability in a capability list.
type (:<) :: Capability -> [Capability] -> Constraint
class a :< b

instance c :< (c ': _cs)
instance Throw e :< (ThrowAny ': _cs)
instance {-# OVERLAPPABLE #-} c :< cs => c :< (_x ': cs)


-- | Constraint to assert the existence of a list of capabilities in a capability list.
type (:<<) :: [k] -> [k] -> Constraint
type family a :<< b where
  '[] :<< _ = ()
  (n ': ns) :<< as = (n :< as, ns :<< as)

-- | Concatenate two type-level lists.
type (:++) :: [k] -> [k] -> [k]
type family a :++ b where
  '[] :++ rs = rs
  ls :++ '[] = ls
  (l ': ls) :++ rs = l ': (ls :++ rs)

-- | Remove an element from a type-level list. Has special handling for `ThrowAny`, which als removes any `Throw e`.
type (:-) :: [k] -> k -> [k]
type family a :- b where
  '[] :- _ = '[]
  (Throw _ ': xs) :- ThrowAny = xs :- ThrowAny
  (r ': xs) :- r = xs :- r
  (x ': xs) :- r = x ': (xs :- r)


type HasCapability :: Capability -> (Type -> Type) -> Constraint
class UnsafeLiftBase m => HasCapability c m

instance (HasCapability c m, MonadTrans t, Monad (t m)) => HasCapability c (t m)


-- * ThrowAny

type ThrowAny :: Capability
class UnsafeLiftBase m => ThrowAny m where
  throwAny :: Exception e => e -> m a

instance (HasCapability ThrowAny m, MonadThrow (UnsafeBaseMonad m), UnsafeLiftBase m) => ThrowAny m where
  throwAny = unsafeLiftBase . throwM

instance HasCapability ThrowAny IO
instance HasCapability ThrowAny STM


-- * Throw e

type Throw :: Type -> Capability
class UnsafeLiftBase m => Throw e m where
  throwC :: Exception e => e -> m a

instance (HasCapability (Throw e) m, ThrowAny (UnsafeBaseMonad m), UnsafeLiftBase m) => Throw e m where
  throwC = unsafeLiftBase . throwAny

instance {-# INCOHERENT #-} HasCapability ThrowAny m => HasCapability (Throw e) m


-- * RequireCapabilities

type RequireCapabilities :: [Capability] -> (Type -> Type) -> Constraint
type family RequireCapabilities caps m where
  RequireCapabilities '[] _ = ()
  RequireCapabilities (c ': cs) m =
    (
      HasCapability c m,
      c m,
      RequireCapabilities cs m
    )


-- * UnsafeLiftBase

type UnsafeLiftBase :: (Type -> Type) -> Constraint
class Monad m => UnsafeLiftBase m where
  type UnsafeBaseMonad m :: (Type -> Type)
  unsafeLiftBase :: UnsafeBaseMonad m a -> m a

instance (MonadTrans t, UnsafeLiftBase m, Monad (t m)) => UnsafeLiftBase (t m) where
  type UnsafeBaseMonad (t m) = UnsafeBaseMonad m
  unsafeLiftBase = lift . unsafeLiftBase

instance UnsafeLiftBase IO where
  type UnsafeBaseMonad IO = IO
  unsafeLiftBase = id

instance UnsafeLiftBase STM where
  type UnsafeBaseMonad STM = STM
  unsafeLiftBase = id
