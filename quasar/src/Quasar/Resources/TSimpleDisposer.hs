{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.TSimpleDisposer (
  TSimpleDisposerState,
  TSimpleDisposerElement(..),
  TSimpleDisposer(..),
  newUnmanagedTSimpleDisposer,
  disposeTSimpleDisposer,
  disposeTSimpleDisposerElement,
  trivialTSimpleDisposer,
) where

import Quasar.Resources.Core
