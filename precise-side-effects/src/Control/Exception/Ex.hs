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
) where

import Control.Exception
import Data.Kind
import Type.Reflection
import Prelude
import Data.Coerce (coerce)


-- | Constraint to assert the existence of a type in a type-level list.
type (:<) :: k -> [k] -> Constraint
type family a :< b where
  x :< (x ': _) = ()
  x :< (_ ': ns) = (x :< ns)

-- | Constraint to assert the existence of a list of types in a type-level list.
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
      Just _ -> Just (ExCtor se)


type role Ex phantom
type Ex :: [Type] -> Type
newtype Ex exceptions = ExCtor SomeException

toEx :: (Exception e, e :< exceptions) => e -> Ex exceptions
toEx = ExCtor . toException

instance ExceptionList exceptions => Exception (Ex exceptions) where
  toException (ExCtor ex) = ex
  fromException = someExceptionToEx @exceptions
  displayException (ExCtor ex) = displayException ex

instance Show (Ex exceptions) where
  show (ExCtor ex) = show ex

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
absurdEx = undefined -- unreachable code path
