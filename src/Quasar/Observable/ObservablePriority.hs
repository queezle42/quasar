module Quasar.Observable.ObservablePriority (
  ObservablePriority,
  create,
  insertValue,
) where

import Data.HashMap.Strict qualified as HM
import Data.List (maximumBy)
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Ord (comparing)
import Quasar.Core
import Quasar.Observable
import Quasar.Prelude

type Entry v = (Unique, v)

-- | Mutable data structure that stores values of type "v" with an assiciated priority "p". The `IsObservable` instance can be used to get or observe the value with the highest priority.
newtype ObservablePriority p v = ObservablePriority (MVar (Internals p v))

instance IsGettable (Maybe v) (ObservablePriority p v) where
  getValue (ObservablePriority mvar) = liftIO $ getValueFromInternals <$> readMVar mvar
    where
      getValueFromInternals :: Internals p v -> Maybe v
      getValueFromInternals Internals{current=Nothing} = Nothing
      getValueFromInternals Internals{current=Just (_, _, value)} = Just value
instance IsObservable (Maybe v) (ObservablePriority p v) where
  subscribe (ObservablePriority mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \internals@Internals{subscribers} -> do
      -- Call listener
      callback (Current, currentValue internals)
      pure internals{subscribers = HM.insert key callback subscribers}
    pure $ synchronousDisposable (unsubscribe key)
    where
      unsubscribe :: Unique -> IO ()
      unsubscribe key = modifyMVar_ mvar $ \internals@Internals{subscribers} -> pure internals{subscribers=HM.delete key subscribers}

type PriorityMap p v = HM.HashMap p (NonEmpty (Entry v))

data Internals p v = Internals {
  priorityMap :: PriorityMap p v,
  current :: Maybe (Unique, p, v),
  subscribers :: HM.HashMap Unique (ObservableCallback (Maybe v))
}

-- | Create a new `ObservablePriority` data structure.
create :: IO (ObservablePriority p v)
create = ObservablePriority <$> newMVar Internals {
    priorityMap = HM.empty,
    current = Nothing,
    subscribers = HM.empty
  }

currentValue :: Internals k v -> Maybe v
currentValue Internals{current} = (\(_, _, value) -> value) <$> current

-- | Insert a value with an assigned priority into the data structure. If the priority is higher than the current highest priority the value will become the current value (and will be sent to subscribers). Otherwise the value will be stored and will only become the current value when all values with a higher priority and all values with the same priority that have been inserted earlier have been removed.
-- Returns an `Disposable` that can be used to remove the value from the data structure.
insertValue :: forall p v. (Ord p, Hashable p) => ObservablePriority p v -> p -> v -> IO Disposable
insertValue (ObservablePriority mvar) priority value = modifyMVar mvar $ \internals -> do
  key <- newUnique
  newInternals <- insertValue' key internals
  pure (newInternals, synchronousDisposable (removeValue key))
  where
    insertValue' :: Unique -> Internals p v -> IO (Internals p v)
    insertValue' key internals@Internals{priorityMap, current}
      | hasToUpdateCurrent current = do
        let newInternals = internals{priorityMap=insertEntry priorityMap, current=Just (key, priority, value)}
        notifySubscribers newInternals
        pure newInternals
      | otherwise = pure internals{priorityMap=insertEntry priorityMap}
      where
        insertEntry :: PriorityMap p v -> PriorityMap p v
        insertEntry = HM.alter addToEntryList priority
        addToEntryList :: Maybe (NonEmpty (Entry v)) -> Maybe (NonEmpty (Entry v))
        addToEntryList Nothing = Just newEntryList
        addToEntryList (Just list) = Just (list <> newEntryList)
        newEntryList :: NonEmpty (Entry v)
        newEntryList = (key, value) :| []

        hasToUpdateCurrent :: (Maybe (Unique, p, v)) -> Bool
        hasToUpdateCurrent Nothing = True
        hasToUpdateCurrent (Just (_, oldPriority, _)) = priority > oldPriority

    removeValue :: Unique -> IO ()
    removeValue key = modifyMVar_ mvar removeValue'
      where
        removeValue' :: Internals p v -> IO (Internals p v)
        removeValue' internals@Internals{priorityMap, current} = do
          let newInternals = internals{priorityMap = removeEntry priorityMap}
          if hasToUpdateCurrent current
            then updateCurrent newInternals
            else pure newInternals

        removeEntry :: PriorityMap p v -> PriorityMap p v
        removeEntry = HM.alter removeEntryFromList priority
        removeEntryFromList :: Maybe (NonEmpty (Entry v)) -> Maybe (NonEmpty (Entry v))
        removeEntryFromList Nothing = Nothing
        removeEntryFromList (Just list) = nonEmpty $ NonEmpty.filter (\(key', _) -> key' /= key) list

        updateCurrent :: Internals p v -> IO (Internals p v)
        updateCurrent internals@Internals{priorityMap} = do
          let newInternals = internals{current = selectCurrent $ HM.toList priorityMap}
          notifySubscribers newInternals
          pure newInternals
        selectCurrent :: [(p, (NonEmpty (Entry v)))] -> Maybe (Unique, p, v)
        selectCurrent [] = Nothing
        selectCurrent list = Just . selectCurrentFromList . maximumBy (comparing fst) $ list
          where
            selectCurrentFromList :: (p, (NonEmpty (Entry v))) -> (Unique, p, v)
            selectCurrentFromList (priority', entryList) = (key', priority', value')
              where
                (key', value') = NonEmpty.head entryList

        hasToUpdateCurrent :: (Maybe (Unique, p, v)) -> Bool
        hasToUpdateCurrent Nothing = False
        hasToUpdateCurrent (Just (oldKey, _, _)) = key == oldKey


notifySubscribers :: forall p v. Internals p v -> IO ()
notifySubscribers Internals{subscribers, current} = forM_ subscribers (\callback -> callback (Update, (\(_, _, value) -> value) <$> current))
