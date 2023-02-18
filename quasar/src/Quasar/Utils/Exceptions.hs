module Quasar.Utils.Exceptions (
  CombinedException(..),
  mkCombinedException,
  combinedExceptions,
) where

import Control.Exception
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Quasar.Prelude

newtype CombinedException = CombinedException (NonEmpty SomeException)
  deriving stock Show

mkCombinedException :: [SomeException] -> Maybe CombinedException
mkCombinedException exs = CombinedException <$> nonEmpty exs

instance Exception CombinedException where
  displayException (CombinedException exceptions) = intercalate "\n" (header : exceptionMessages)
    where
      header = mconcat ["CombinedException with ", show (length exceptions), "exceptions:"]
      exceptionMessages = displayException <$> toList exceptions

combinedExceptions :: CombinedException -> [SomeException]
combinedExceptions (CombinedException exceptions) = toList exceptions
