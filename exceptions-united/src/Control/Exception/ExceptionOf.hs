{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE Trustworthy #-}

module Control.Exception.ExceptionOf (
  ExceptionOf,
  toExceptionOf,
  matchExceptionOf,
  extendExceptionOf,
  absurdException,
) where

import Control.Exception
import Data.Kind
import Type.Reflection
import Prelude
import Data.Coerce (coerce)


-- | Constraint to assert the existence of a type in a type list.
type (:<) :: k -> [k] -> Constraint
type family a :< b where
  x :< (x ': _) = ()
  x :< (_ ': ns) = (x :< ns)

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

-- | Remove an element from a type-level list.
type (:-) :: [k] -> k -> [k]
type family a :- b where
  '[] :- _ = '[]
  (r ': xs) :- r = xs :- r
  (x ': xs) :- r = x ': (xs :- r)


type ExceptionList :: [Type] -> Constraint
type ExceptionList exceptions = (ToExceptionOf exceptions exceptions, Typeable exceptions)

type ToExceptionOf :: [Type] -> [Type] -> Constraint
class (es :<< exceptions) => ToExceptionOf es exceptions where
  someExceptionToExceptionOf :: SomeException -> Maybe (ExceptionOf exceptions)

instance ToExceptionOf '[] _exceptions where
  someExceptionToExceptionOf _ = Nothing

instance (Exception e, e :< exceptions, ToExceptionOf es exceptions) => ToExceptionOf (e ': es) exceptions where
  someExceptionToExceptionOf se =
    case fromException @e se of
      Nothing -> someExceptionToExceptionOf @es se
      Just _ -> Just (ExceptionOfCtor se)


type role ExceptionOf phantom
type ExceptionOf :: [Type] -> Type
newtype ExceptionOf exceptions = ExceptionOfCtor SomeException

toExceptionOf :: (Exception e, e :< exceptions) => e -> ExceptionOf exceptions
toExceptionOf = ExceptionOfCtor . toException

instance ExceptionList exceptions => Exception (ExceptionOf exceptions) where
  toException (ExceptionOfCtor ex) = ex
  fromException = someExceptionToExceptionOf @exceptions
  displayException (ExceptionOfCtor ex) = displayException ex

instance Show (ExceptionOf exceptions) where
  show (ExceptionOfCtor ex) = show ex

matchExceptionOf ::
  (Exception e, ExceptionList exceptions) =>
  ExceptionOf exceptions ->
  Either (ExceptionOf (exceptions :- e)) e
matchExceptionOf ex =
  case fromException (toException ex) of
    Just matchedException -> Right matchedException
    Nothing -> Left (coerce ex)

extendExceptionOf :: (sub :<< super) => ExceptionOf sub -> ExceptionOf super
extendExceptionOf = coerce

absurdException :: ExceptionOf '[] -> a
absurdException = undefined -- unreachable code path
