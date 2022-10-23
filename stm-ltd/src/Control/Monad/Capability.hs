{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Control.Monad.Capability (
  Capability,
  ApplyConstraints,
  (:<),
  (:<<),
  (:++),
  Throw(..),
  ThrowAny,
  throwAny,
) where

import Control.Monad.Catch
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM (STM)
import Control.Monad.Trans.Class
import Prelude
import Data.Kind

type Capability = (Type -> Type) -> Constraint


type ApplyConstraints :: [Capability] -> (Type -> Type) -> Constraint
type family ApplyConstraints a m :: Constraint where
  ApplyConstraints '[] _ = ()
  ApplyConstraints (cap ': caps) m = (cap m, ApplyConstraints caps m)


type (:<) :: k -> [k] -> Constraint
type family a :< b where
  c :< (c ': _) = ()
  c :< (_ ': cs) = c :< cs

type (:<<) :: [k] -> [k] -> Constraint
type family a :<< b where
  '[] :<< _ = ()
  (n ': ns) :<< as = (n :< as, ns :<< as)

type (:++) :: [k] -> [k] -> [k]
type family a :++ b where
  '[] :++ rs = rs
  (l ': ls) :++ rs = l ': (ls :++ rs)



class Monad m => Throw e m where
  throwC :: Exception e => e -> m a

instance Throw e STM where
  throwC = STM.throwSTM

instance (Throw e m, MonadTrans t, Monad (t m)) => Throw e (t m) where
  throwC = lift . throwC

type ThrowAny = Throw SomeException

throwAny :: (Exception e, ThrowAny m) => e -> m a
throwAny = throwC . toException
