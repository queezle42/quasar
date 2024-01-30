{-# LANGUAGE RoleAnnotations #-}

module Quasar.Future (
  ToFuture,
) where

import Quasar.Prelude

type ToFuture :: [Type] -> Type -> Type -> Constraint
class ToFuture e r a | a -> e, a -> r
