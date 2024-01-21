module Quasar.Observable.ObservableList (
  -- * ObservableList interface
  ToObservableList(..),
  attachListDeltaObserver,
  IsObservableList(..),
  ObservableList,
  length,
  isEmpty,

  -- ** Deltas
  ObservableListDelta(..),
  ObservableListOperation(..),
  singletonDelta,
  packDelta,

  -- * Mutable ObservableListVar container
  ObservableListVar,
  newObservableListVar,
  newObservableListVarIO,
  newEmptyObservableListVar,
  newEmptyObservableListVarIO,
  insert,
  delete,
  lookup,
  lookupDelete,
) where

import Data.Foldable qualified as Foldable
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Quasar.Observable
import Quasar.Prelude hiding (filter, length)
import Quasar.Resources
import Quasar.Utils.CallbackRegistry


class ToObservable (Seq v) a => ToObservableList v a | a -> v where
  toObservableList :: a -> ObservableList v
  default toObservableList :: IsObservableList v a => a -> ObservableList v
  toObservableList = ObservableList

class ToObservableList v a => IsObservableList v a | a -> v where
  observeIsEmpty# :: a -> Observable Bool

  observeLength# :: a -> Observable Int

  -- | Register a listener to observe changes to the whole map. The callback
  -- will be invoked with the current state of the map immediately after
  -- registering and after that will be invoked for every change to the map.
  attachListDeltaObserver# :: a -> (ObservableListDelta v -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TDisposer, Seq v)

attachListDeltaObserver :: (ToObservableList v a, MonadSTMc NoRetry '[] m) => a -> (ObservableListDelta v -> STMc NoRetry '[] ()) -> m (TDisposer, Seq v)
attachListDeltaObserver x callback = liftSTMc $ attachListDeltaObserver# (toObservableList x) callback

length :: ToObservableList v a => a -> Observable Int
length = observeLength# . toObservableList

isEmpty :: ToObservableList v a => a -> Observable Bool
isEmpty = observeIsEmpty# . toObservableList

-- TODO length, isEmpty

data ObservableList v = forall a. IsObservableList v a => ObservableList a

instance ToObservable (Seq v) (ObservableList v) where
  toObservable (ObservableList x) = toObservable x

instance ToObservableList v (ObservableList v) where
  toObservableList = id

instance IsObservableList v (ObservableList v) where
  observeIsEmpty# (ObservableList x) = observeIsEmpty# x
  observeLength# (ObservableList x) = observeLength# x
  attachListDeltaObserver# (ObservableList x) = attachListDeltaObserver# x

instance Functor ObservableList where
  fmap f x = toObservableList (MappedObservableList f x)


-- | A single operation that can be applied to an `ObservableList`. Part of a
-- `ObservableListDelta`.
--
-- `Insert` indices are clamped to @[0, length]@.
--
-- Applying `Delete` to a non-existing index is a no-op.
data ObservableListOperation v
  = Insert Int v
  | Delete Int
  | DeleteAll

instance Functor ObservableListOperation where
  fmap f (Insert k v) = Insert k (f v)
  fmap _ (Delete k) = Delete k
  fmap _ DeleteAll = DeleteAll


-- | A list of operations that is applied atomically to an `ObservableList`.
newtype ObservableListDelta v = ObservableListDelta (Seq (ObservableListOperation v))

instance Functor ObservableListDelta where
  fmap f (ObservableListDelta ops) = ObservableListDelta (f <<$>> ops)

instance Semigroup (ObservableListDelta v) where
  ObservableListDelta x <> ObservableListDelta y = ObservableListDelta (go x y)
    where
      go :: Seq (ObservableListOperation v) -> Seq (ObservableListOperation v) -> Seq (ObservableListOperation v)
      go _ ys@(DeleteAll :<| _) = ys
      go (xs :|> Insert key1 _) (Delete key2 :<| ys) | key1 == key2 = go xs ys
      go xs ys = xs <> ys

instance Monoid (ObservableListDelta v) where
  mempty = ObservableListDelta mempty

singletonDelta :: ObservableListOperation v -> ObservableListDelta v
singletonDelta x = ObservableListDelta (Seq.singleton x)

-- | Pack a sequence of `ObservableListOperation`s into a `ObservableListDelta`.
--
-- Removes unnecessary updates (all updates preceding an `DeleteAll` or an
-- `Insert` followed by a `Delete` for the same element.
packDelta :: Foldable t => t (ObservableListOperation v) -> ObservableListDelta v
packDelta x =
  -- The list is passed through the semigroup instance so duplicate updates are
  -- filtered.
  mconcat $ singletonDelta <$> toList x


data MappedObservableList v = forall a. MappedObservableList (a -> v) (ObservableList a)

instance ToObservable (Seq v) (MappedObservableList v) where
  toObservable (MappedObservableList fn observable) = fn <<$>> toObservable observable

instance ToObservableList v (MappedObservableList v)

instance IsObservableList v (MappedObservableList v) where
  observeIsEmpty# (MappedObservableList _ observable) = observeIsEmpty# observable
  observeLength# (MappedObservableList _ observable) = observeLength# observable
  attachListDeltaObserver# (MappedObservableList fn observable) callback =
    fmap fn <<$>> attachListDeltaObserver# observable (\update -> callback (fn <$> update))


data ObservableListVar v = ObservableListVar {
  content :: TVar (Seq v),
  observers :: CallbackRegistry (Seq v),
  deltaObservers :: CallbackRegistry (ObservableListDelta v),
  keyObservers :: TVar (Seq (CallbackRegistry (Maybe v)))
}

instance ToObservable (Seq v) (ObservableListVar v)

instance IsObservable (Seq v) (ObservableListVar v) where
  readObservable# ObservableListVar{content} = readTVar content
  attachObserver# ObservableListVar{content, observers} callback = do
    disposer <- registerCallback observers callback
    value <- readTVar content
    pure (disposer, value)

instance ToObservableList v (ObservableListVar v)

instance IsObservableList v (ObservableListVar v) where
  observeIsEmpty# x = deduplicateObservable (Seq.null <$> toObservable x)
  observeLength# x = deduplicateObservable (Seq.length <$> toObservable x)
  attachListDeltaObserver# ObservableListVar{content, deltaObservers} callback = do
    disposer <- registerCallback deltaObservers callback
    initial <- readTVar content
    pure (disposer, initial)


data ObservableListVarIndexObservable v = ObservableListVarIndexObservable Int (ObservableListVar v)

instance ToObservable (Maybe v) (ObservableListVarIndexObservable v)

instance IsObservable (Maybe v) (ObservableListVarIndexObservable v) where
  attachObserver# (ObservableListVarIndexObservable index ObservableListVar{content, keyObservers}) callback = do
    value <- Seq.lookup index <$> readTVar content
    registry <- do
      ko <- readTVar keyObservers
      case Seq.lookup index ko of
        Just registry -> pure registry
        Nothing -> do
          registry <- newCallbackRegistryWithEmptyCallback (modifyTVar keyObservers (Seq.deleteAt index))
          modifyTVar keyObservers (Seq.insertAt index registry)
          pure registry
    disposer <- registerCallback registry callback
    pure (disposer, value)

  readObservable# (ObservableListVarIndexObservable index ObservableListVar{content}) =
    Seq.lookup index <$> readTVar content

newObservableListVar :: MonadSTMc NoRetry '[] m => [v] -> m (ObservableListVar v)
newObservableListVar values = liftSTMc @NoRetry @'[] do
  content <- newTVar (Seq.fromList values)
  observers <- newCallbackRegistry
  deltaObservers <- newCallbackRegistry
  keyObservers <- newTVar Seq.empty
  pure ObservableListVar {content, observers, deltaObservers, keyObservers}

newEmptyObservableListVar :: MonadSTMc NoRetry '[] m => m (ObservableListVar v)
newEmptyObservableListVar = newObservableListVar []

newObservableListVarIO :: MonadIO m => [v] -> m (ObservableListVar v)
newObservableListVarIO values = liftIO do
  content <- newTVarIO (Seq.fromList values)
  observers <- newCallbackRegistryIO
  deltaObservers <- newCallbackRegistryIO
  keyObservers <- newTVarIO Seq.empty
  pure ObservableListVar {content, observers, deltaObservers, keyObservers}

newEmptyObservableListVarIO :: MonadIO m => m (ObservableListVar v)
newEmptyObservableListVarIO = newObservableListVarIO []

insert :: forall v m. (MonadSTMc NoRetry '[] m) => Int -> v -> ObservableListVar v -> m ()
insert index value ObservableListVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  initial <- readTVar content
  let clampedIndex = min (max index 0) (Foldable.length initial)
  state <- stateTVar content (dup . Seq.insertAt clampedIndex value)
  callCallbacks observers state
  callCallbacks deltaObservers (singletonDelta (Insert clampedIndex value))
  mkr <- Seq.lookup index <$> readTVar keyObservers
  forM_ mkr \keyRegistry -> callCallbacks keyRegistry (Just value)

delete :: forall v m. (MonadSTMc NoRetry '[] m) => Int -> ObservableListVar v -> m ()
delete index ObservableListVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  initial <- readTVar content
  when (index >= 0 && index < Foldable.length initial) do
    let state = Seq.deleteAt index initial
    callCallbacks observers state
    callCallbacks deltaObservers (singletonDelta (Delete index))
    mkr <- Seq.lookup index <$> readTVar keyObservers
    forM_ mkr \keyRegistry -> callCallbacks keyRegistry Nothing

lookupDelete :: forall v m. (MonadSTMc NoRetry '[] m) => Int -> ObservableListVar v -> m (Maybe v)
lookupDelete index ObservableListVar{content, observers, deltaObservers, keyObservers} = liftSTMc @NoRetry @'[] do
  initial <- readTVar content
  if index >= 0 && index < Foldable.length initial
    then do
      (result, newList) <- stateTVar content \orig ->
        let
          result = Seq.lookup index orig
          newList = Seq.deleteAt index orig
        in ((result, newList), newList)
      callCallbacks observers newList
      callCallbacks deltaObservers (singletonDelta (Delete index))
      mkr <- Seq.lookup index <$> readTVar keyObservers
      forM_ mkr \keyRegistry -> callCallbacks keyRegistry Nothing
      pure result
    else
      pure Nothing
