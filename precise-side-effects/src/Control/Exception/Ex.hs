{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE Trustworthy #-}

module Control.Exception.Ex (
  Ex,
  toEx,
  ExceptionList,
  matchEx,
  extendEx,
  absurdEx,
  ThrowEx(..),
) where

import Control.Exception (Exception(..), SomeException)
import Data.Coerce (coerce)
import Data.Kind
import GHC.TypeLits
import Prelude
import Type.Reflection


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

---- | Concatenate two type-level exception lists.
--type (:++) :: [Type] -> [Type] -> [Type]
--type family a :++ b where
--  '[] :++ rs = rs
--  ls :++ '[] = ls
--  (l ': ls) :++ rs = l ': (ls :++ rs)

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

toEx :: (Exception e, e :< exceptions) => e -> Ex exceptions
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


type ThrowEx :: [Type] -> (Type -> Type) -> Constraint
class ThrowEx allowedExceptions m | m -> allowedExceptions where
  throwEx :: (exceptions :<< allowedExceptions, Exception (Ex exceptions)) => Ex exceptions -> m a
