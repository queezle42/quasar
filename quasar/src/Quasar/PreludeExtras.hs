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
import Data.HashMap.Strict qualified as HM
import Data.HashSet qualified as HS
import Data.Hashable qualified as Hashable
import Data.List qualified as List
import Data.Maybe qualified as Maybe
import Data.Tuple (swap)
import GHC.Stack.Types qualified
import Quasar.Utils.ExtraT

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

-- | Lookup and delete a value from a HashMap in one operation
lookupDelete :: forall k v. Hashable.Hashable k => k -> HM.HashMap k v -> (Maybe v, HM.HashMap k v)
lookupDelete key m = swap $ State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (HM.HashMap k v)
    fn = HM.alterF (\c -> State.put c >> return Nothing) key m

-- | Lookup a value and insert the given value if it is not already a member of the HashMap.
lookupInsert :: forall k v. Hashable.Hashable k => k -> v -> HM.HashMap k v -> (v, HM.HashMap k v)
lookupInsert key value hm = runExtra $ HM.alterF fn key hm
  where
    fn :: Maybe v -> Extra v (Maybe v)
    fn Nothing = Extra (value, Just value)
    fn (Just oldValue) = Extra (oldValue, Just oldValue)

-- | Insert the given value if it is not already a member of the HashMap. Returns `True` if the element was inserted.
checkInsert :: forall k v. Hashable.Hashable k => k -> v -> HM.HashMap k v -> (Bool, HM.HashMap k v)
checkInsert key value hm = runExtra $ HM.alterF fn key hm
  where
    fn :: Maybe v -> Extra Bool (Maybe v)
    fn Nothing = Extra (True, Just value)
    fn (Just oldValue) = Extra (False, Just oldValue)

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
