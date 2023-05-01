-- This module only contains helper functions that are added to the prelude
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Quasar.PreludeExtras where

-- Use prelude from `base` to prevent module import cycle.
import Prelude

import Control.Applicative (liftA2)
import Control.Concurrent (threadDelay)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.State.Lazy as State
import Data.Char qualified as Char
import Data.HashSet qualified as HS
import Data.Hashable qualified as Hashable
import Data.List qualified as List
import Data.Maybe qualified as Maybe
import GHC.Stack.Types qualified

io :: IO a -> IO a
io = id

unreachableCodePath :: GHC.Stack.Types.HasCallStack => a
unreachableCodePath = error "Code path marked as unreachable was reached"

impossibleCodePath :: GHC.Stack.Types.HasCallStack => a
impossibleCodePath = error "Code path marked as impossible was reached"
{-# DEPRECATED impossibleCodePath "Use unreachableCodePath instead" #-}

unreachableCodePathM :: MonadThrow m => m a
unreachableCodePathM = throwM (userError "Code path marked as unreachable was reached")

impossibleCodePathM :: MonadThrow m => m a
impossibleCodePathM = throwM (userError "Code path marked as impossible was reached")
{-# DEPRECATED impossibleCodePathM "Use unreachableCodePathM instead" #-}

intercalate :: (Foldable f, Monoid a) => a -> f a -> a
intercalate inter = foldr1 (\a b -> a <> inter <> b)

dropPrefix :: Eq a => [a] -> [a] -> [a]
dropPrefix prefix list = Maybe.fromMaybe list $ List.stripPrefix prefix list

dropSuffix :: Eq a => [a] -> [a] -> [a]
dropSuffix suffix list = maybe list reverse $ List.stripPrefix (reverse suffix) (reverse list)

aesonDropPrefix :: String -> String -> String
aesonDropPrefix prefix = decapitalize . dropPrefix prefix
  where
    decapitalize (x:xs) = Char.toLower x : xs
    decapitalize [] = []

maybeToEither :: b -> Maybe a -> Either b a
maybeToEither _ (Just x) = Right x
maybeToEither y Nothing  = Left y

rightToMaybe :: Either a b -> Maybe b
rightToMaybe (Left _) = Nothing
rightToMaybe (Right x) = Just x

leftToMaybe :: Either a b -> Maybe a
leftToMaybe (Left x) = Just x
leftToMaybe (Right _) = Nothing

-- | Returns all duplicate elements in a list. The order of the produced list is unspecified.
duplicates :: forall a. Hashable.Hashable a => [a] -> [a]
duplicates = HS.toList . duplicates' HS.empty
  where
    duplicates' :: HS.HashSet a -> [a] -> HS.HashSet a
    duplicates' _ [] = HS.empty
    duplicates' set (x:xs)
      | HS.member x set = HS.insert x otherDuplicates
      | otherwise = otherDuplicates
      where
        otherDuplicates = duplicates' (HS.insert x set) xs

infixl 4 <<$>>
(<<$>>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<<$>>) = fmap . fmap

infixl 4 <<*>>
(<<*>>) :: (Applicative f, Applicative g) => f (g (a -> b)) -> f (g a) -> f (g b)
(<<*>>) = liftA2 (<*>)

infixr 6 <<>>
(<<>>) :: (Applicative f, Semigroup a) => f a -> f a -> f a
(<<>>) = liftA2 (<>)

dup :: a -> (a, a)
dup x = (x, x)

-- | Enumerate all values of an 'Enum'
enumerate :: (Enum a, Bounded a) => [a]
enumerate = [minBound..maxBound]

-- | Splits a list using a predicate. The separator is removed. The opposite of `intercalate`.
splitOn :: (a -> Bool) -> [a] -> [[a]]
splitOn p s = case break p s of
  (w, []) -> [w]
  (w, _:r) -> w : splitOn p r

sleepForever :: MonadIO m => m a
sleepForever = liftIO $ forever $ threadDelay 1000000000000

-- | Monadic version of @when@, taking the condition in the monad
whenM :: Monad m => m Bool -> m () -> m ()
whenM mb action = do
  b <- mb
  when b action

-- | Monadic version of @unless@, taking the condition in the monad
unlessM :: Monad m => m Bool -> m () -> m ()
unlessM condM acc = do
  cond <- condM
  unless cond acc

fmap2 :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
fmap2 = fmap . fmap

fmap3 :: (Functor f, Functor g, Functor h) => (a -> b) -> f (g (h a)) -> f (g (h b))
fmap3 = fmap . fmap . fmap

fmap4 :: (Functor f, Functor g, Functor h, Functor i) => (a -> b) -> f (g (h (i a))) -> f (g (h (i b)))
fmap4 = fmap . fmap . fmap . fmap
