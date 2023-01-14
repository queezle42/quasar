{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Control.Exception.Ex (
  Ex,
  toEx,
  ExceptionList,
  matchEx,
  extendEx,
  absurdEx,

  Throw(..),
  ThrowAny,
  ThrowEx(..),
  throwEx,
  ThrowForAll,

  -- TODO maybe
  --Throw(throwC),

  (:<),
  (:<<),
  (:-),
  (:--),
) where

import Control.Concurrent.STM (STM, throwSTM)
import Control.Exception (Exception(..), SomeException, throwIO)
import Control.Monad.Catch (MonadThrow (throwM))
import Data.Coerce (coerce)
import Data.Kind
import GHC.TypeLits
import Prelude
import Type.Reflection
import Control.Monad.Trans.Class (MonadTrans (lift))


-- | Constraint to assert the existence of an exception in a type-level list.
--
-- The lhs may also be of type `Ex`, in which case all possible exceptions are
-- asserted to be in the rhs.
--
-- The rhs must not contain `Ex`.
type (:<) :: Type -> [Type] -> Constraint

type family a :< b where
  _ :< (SomeException ': _) = ()
  _ :< (Ex _ ': _) = TypeError ('Text "Invalid usage of ‘Ex’ in rhs of type family ‘:<’")
  Ex exceptions :< xs = exceptions :<< xs
  x :< (x ': _) = ()
  x :< (_ ': ns) = (x :< ns)

--class a :< b
--
--instance _e :< (SomeException ': _xs)
----instance {-# INCOHERENT #-} SomeException :< xs => _e :< xs
--
--instance exceptions :<< xs => Ex exceptions :< xs
--
--instance {-# OVERLAPS #-} e :< (e ': _xs)
--
--instance e :< xs => e :< (_x ': xs)


-- | Constraint to assert the existence of a list of exceptions in a type-level list.
--
-- The lhs may also contain type `Ex`, in which case all exceptions of `Ex` are
-- asserted to be in the rhs.
--
-- The rhs must not contain `Ex`.
type (:<<) :: [Type] -> [Type] -> Constraint
type family a :<< b where
  '[] :<< _ = ()
  (n ': ns) :<< as = (n :< as, ns :<< as)

-- | Remove an exception from a type-level list.
--
-- The rhs may also be of type `Ex`, in which case all possible exceptions are
-- removed from the lhs.
--
-- The lhs must not contain `Ex`.
type (:-) :: [Type] -> Type -> [Type]
type family a :- b where
  '[] :- _ = '[]
  (Ex _ ': _) :- _ = TypeError ('Text "Invalid usage of ‘Ex’ in lhs of type family ‘:-’")
  _ :- SomeException = '[]
  xs :- (Ex exceptions) = xs :-- exceptions
  (r ': xs) :- r = xs :- r
  (x ': xs) :- r = x ': (xs :- r)

-- | Remove an exception from a type-level list.
--
-- The rhs may also contain type `Ex`, in which case all possible exceptions are
-- removed from the lhs.
--
-- The lhs must not contain `Ex`.
type (:--) :: [Type] -> [Type] -> [Type]
type family a :-- b where
  xs :-- '[] = xs
  xs :-- (e ': es) = (xs :- e) :-- es


type ExceptionList :: [Type] -> Constraint
type ExceptionList exceptions = (ToEx exceptions exceptions, Typeable exceptions)

type ToEx :: [Type] -> [Type] -> Constraint
class (es :<< exceptions) => ToEx es exceptions where
  someExceptionToEx :: SomeException -> Maybe (Ex exceptions)

instance ToEx '[] _exceptions where
  someExceptionToEx _ = Nothing

instance (Exception e, e :< exceptions, ToEx es exceptions) => ToEx (e ': es) exceptions where
  someExceptionToEx se =
    case fromException @e se of
      Nothing -> someExceptionToEx @es se
      Just _ -> Just (Ex se)


type role Ex phantom
type Ex :: [Type] -> Type
newtype Ex exceptions = Ex SomeException

toEx :: forall exceptions e. (Exception e, e :< exceptions) => e -> Ex exceptions
toEx = Ex . toException

instance ExceptionList exceptions => Exception (Ex exceptions) where
  toException (Ex ex) = ex
  fromException = someExceptionToEx @exceptions
  displayException (Ex ex) = displayException ex

instance Show (Ex exceptions) where
  show (Ex ex) = show ex

matchEx ::
  (Exception e, ExceptionList exceptions) =>
  Ex exceptions ->
  Either (Ex (exceptions :- e)) e
matchEx ex =
  case fromException (toException ex) of
    Just matchedException -> Right matchedException
    Nothing -> Left (coerce ex)

extendEx :: (sub :<< super) => Ex sub -> Ex super
extendEx = coerce

absurdEx :: Ex '[] -> a
absurdEx = error "unreachable code path"


type ThrowAny = MonadThrow

type Throw :: Type -> (Type -> Type) -> Constraint
class (Exception e, Monad m) => Throw e m where
  throwC :: e -> m a

instance {-# INCOHERENT #-} (Exception e, ThrowAny m) => Throw e m where
  throwC = throwM

instance Exception e => Throw e IO where
  throwC = throwIO

instance Exception e => Throw e STM where
  throwC = throwSTM

instance (Exception e, Throw e m, Monad (t m), MonadTrans t) => Throw e (t m) where
  throwC = lift . throwC

type ThrowForAll :: [Type] -> (Type -> Type) -> Constraint
type family ThrowForAll xs m where
  ThrowForAll '[] _m = ()
  ThrowForAll (SomeException ': xs) m = (ThrowAny m, ThrowForAll xs m)
  ThrowForAll (x ': xs) m = (Throw x m, ThrowForAll xs m)

-- | Monad support for throwing combined exceptions.
--
-- To use this class see `throwEx`.
class Monad m => ThrowEx m where
  -- | Implementation helper. May only ever be called by `throwEx`.
  unsafeThrowEx :: Exception (Ex exceptions) => Ex exceptions -> m a

throwEx :: (ThrowEx m, ThrowForAll exceptions m, Exception (Ex exceptions)) => Ex exceptions -> m a
throwEx = unsafeThrowEx

instance ThrowEx IO where
  unsafeThrowEx = throwIO

instance ThrowEx STM where
  unsafeThrowEx = throwSTM

instance (ThrowEx m, Monad (t m), MonadTrans t) => ThrowEx (t m) where
  unsafeThrowEx = lift . unsafeThrowEx
