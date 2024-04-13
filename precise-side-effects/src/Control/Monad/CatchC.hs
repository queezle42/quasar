module Control.Monad.CatchC (
  MonadCatchC(..),
  catchAllC,
  handleC,
  handleAllC,
  tryAllC,
) where

import Control.Exception (Exception)
import Control.Exception.Ex
import Data.Bifunctor qualified as Bifunctor
import Data.Kind
import Prelude

type MonadCatchC :: ([Type] -> Type -> Type) -> Constraint
class (forall exceptions. Monad (m exceptions)) => MonadCatchC m where
  {-# MINIMAL catchC | tryC #-}

  catchC ::
    (Exception e, MonadCatchC m) =>
    m exceptions a -> (e -> m (exceptions :- e) a) -> m (exceptions :- e) a

  catchC ft fc = tryC ft >>= either fc pure
  {-# INLINABLE catchC #-}

  tryC ::
    (Exception e, MonadCatchC m) =>
    m exceptions a -> m (exceptions :- e) (Either e a)
  tryC f = catchC (Right <$> f) \ex -> pure (Left ex)
  {-# INLINABLE tryC #-}


catchAllC ::
  forall exceptions m a. (
    MonadCatchC m
  ) =>
  m exceptions a -> (Ex exceptions -> m '[] a) -> m '[] a

catchAllC ft fc = catchC ft (fc . unsafeToEx)
{-# INLINABLE catchAllC #-}


handleC ::
  forall exceptions e m a. (
    Exception e,
    MonadCatchC m
  ) =>
  (e -> m (exceptions :- e) a) -> m exceptions a -> m (exceptions :- e) a

handleC = flip catchC
{-# INLINABLE handleC #-}

handleAllC ::
  forall exceptions m a. (
    MonadCatchC m
  ) =>
  (Ex exceptions -> m '[] a) -> m exceptions a -> m '[] a

handleAllC = flip catchAllC
{-# INLINABLE handleAllC #-}


tryAllC ::
  forall exceptions m a. (
    MonadCatchC m
  ) =>
  m exceptions a -> m '[] (Either (Ex exceptions) a)
tryAllC f = Bifunctor.first unsafeToEx <$> tryC f
{-# INLINABLE tryAllC #-}
