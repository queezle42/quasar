module Quasar.PreludeExtras where

-- Use prelude from `base` to prevent module import cycle.
import Prelude

import Quasar.Utils.ExtraT

import Control.Applicative (liftA2)
import Control.Concurrent (threadDelay)
import Control.Monad.State.Lazy as State
import qualified Data.Char as Char
import qualified Data.Hashable as Hashable
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import GHC.Records.Compat (HasField, getField, setField)
import qualified GHC.Stack.Types
import GHC.TypeLits (Symbol)
import Lens.Micro.Platform (Lens', lens)

impossibleCodePath :: GHC.Stack.Types.HasCallStack => a
impossibleCodePath = error "Code path marked as impossible was reached"

impossibleCodePathM :: MonadFail m => m a
impossibleCodePathM = fail "Code path marked as impossible was reached"

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
duplicates :: forall a. (Eq a, Hashable.Hashable a) => [a] -> [a]
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
lookupDelete :: forall k v. (Eq k, Hashable.Hashable k) => k -> HM.HashMap k v -> (HM.HashMap k v, Maybe v)
lookupDelete key m = State.runState fn Nothing
  where
    fn :: State.State (Maybe v) (HM.HashMap k v)
    fn = HM.alterF (\c -> State.put c >> return Nothing) key m

-- | Lookup a value and insert the given value if it is not already a member of the HashMap.
lookupInsert :: forall k v. (Eq k, Hashable.Hashable k) => k -> v -> HM.HashMap k v -> (HM.HashMap k v, v)
lookupInsert key value hm = runExtra $ HM.alterF fn key hm
  where
    fn :: Maybe v -> Extra v (Maybe v)
    fn Nothing = Extra (Just value, value)
    fn (Just oldValue) = Extra (Just oldValue, oldValue)

infixl 4 <<$>>
(<<$>>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<<$>>) = fmap . fmap

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

fieldLens :: forall (x :: Symbol) r a. HasField x r a => Lens' r a
fieldLens = lens (getField @x) (setField @x)

sleepForever :: IO a
sleepForever = forever $ threadDelay 1000000000000
