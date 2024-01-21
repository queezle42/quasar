{-# LANGUAGE RoleAnnotations #-}

module Quasar.Future (
  ToFuture,
) where

import Quasar.Prelude

type ToFuture :: Type -> Type -> Constraint
class ToFuture r a | a -> r
