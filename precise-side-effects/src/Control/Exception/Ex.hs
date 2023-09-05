{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Control.Exception.Ex (
  Ex,
  toEx,
  ExceptionList,
  matchEx,
  limitEx,
  absurdEx,
  exToException,

  Throw(..),
  ThrowAny,
  MonadThrowEx(..),
  ThrowEx,
  throwEx,
  ThrowForAll,

  (:<),
  (:<<),
  (:-),
  (:--),

  -- * Implementation helper
  unsafeToEx
) where

import Control.Concurrent.STM (STM, throwSTM)
import Control.Exception (Exception(..), SomeException, throwIO)
import Control.Monad.Catch (MonadThrow (throwM))
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
  Ex xs :< xs = ()
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
{-# INLINABLE toEx #-}

-- | The quantified type of any exception passed to `unsafeToEx` MUST be
-- contained in @exceptions@.
unsafeToEx :: SomeException -> Ex exceptions
unsafeToEx = Ex

instance ExceptionList exceptions => Exception (Ex exceptions) where
  toException (Ex ex) = ex
  fromException = someExceptionToEx @exceptions
  displayException (Ex ex) = displayException ex

instance Show (Ex exceptions) where
  show (Ex ex) = show ex

-- | Variant of `toException` specifically for `Ex` without the
-- `Exception (Ex exceptions)`-constraint.
exToException :: Ex exceptions -> SomeException
exToException (Ex ex) = ex

matchEx ::
  (Exception e, ExceptionList exceptions) =>
  Ex exceptions ->
  Either (Ex (exceptions :- e)) e
matchEx (Ex ex) =
  case fromException ex of
    Just matchedException -> Right matchedException
    Nothing -> Left (Ex ex)

-- | Specialized version of `toEx` to limit the list of exceptions to a subset.
limitEx :: sub :<< super => Ex sub -> Ex super
limitEx (Ex x) = Ex x


absurdEx :: Ex '[] -> a
absurdEx = error "absurdEx: Code path marked as unreachable was reached. Somewhere an exception with a mismatched type was encapsulated in an `Ex`."


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

instance {-# OVERLAPPABLE #-} (Throw e m, Monad (t m), MonadTrans t) => Throw e (t m) where
  throwC = lift . throwC

type ThrowForAll :: [Type] -> (Type -> Type) -> Constraint
type family ThrowForAll xs m where
  ThrowForAll '[] _m = ()
  ThrowForAll (SomeException ': xs) m = (ThrowAny m, ThrowForAll xs m)
  ThrowForAll (x ': xs) m = (Throw x m, ThrowForAll xs m)

-- | Monad support for throwing combined exceptions.
--
-- To use this class see `throwEx`.
class Monad m => MonadThrowEx m where
  -- | Implementation helper. May only ever be called by `throwEx`.
  unsafeThrowEx :: SomeException -> m a

type ThrowEx exceptions m = (MonadThrowEx m, ThrowForAll exceptions m)

throwEx :: ThrowEx exceptions m => Ex exceptions -> m a
throwEx (Ex ex) = unsafeThrowEx ex

instance MonadThrowEx IO where
  unsafeThrowEx = throwIO

instance MonadThrowEx STM where
  unsafeThrowEx = throwSTM

instance {-# OVERLAPPABLE #-} (MonadThrowEx m, Monad (t m), MonadTrans t) => MonadThrowEx (t m) where
  unsafeThrowEx = lift . unsafeThrowEx
