{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
  IsObservableCore(..),
  readObservableT,
  retrieveObservableT,
  ObservableContainer(..),
  isEmptyDelta,
  ContainerCount(..),

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  LoadKind(..),
#else
  LoadKind,
  Load,
  NoLoad,
#endif

  absurdLoad,

  ObservableT(..),
  ToObservableT(..),

  evaluateObservable,
  mapObservableContent,

  -- ** Additional types
  Loading(..),
  ObservableChange(.., ObservableChangeLiveReplace, ObservableChangeLiveDelta),
  mapObservableChange,
  ObservableUpdate(..),
  updateValidatedDelta,
  EvaluatedObservableChange(..),
  EvaluatedUpdate(.., EvaluatedUpdateOk, EvaluatedUpdateThrow),
  ObservableState(.., ObservableStateLiveOk, ObservableStateLiveEx),
  mapObservableState,
  mergeObservableState,
  ObserverState(.., ObserverStateLoading, ObserverStateLiveOk, ObserverStateLiveEx),
  createObserverState,
  toObservableState,
  applyObservableUpdate,
  applyObservableChange,
  applyEvaluatedObservableChange,
  toInitialChange,
  ObserverContext(..),
  updateObserverContext,
  ObservableFunctor,

  MappedObservable(..),
  BindObservable(..),
  bindObservableT,

  -- *** Query
  Selector(..),
  Bounds,
  Bound(..),

  -- *** Exception wrapper container
  ObservableResult(..),
  unwrapObservableResult,
  unwrapObservableResultIO,
  mapObservableResult,
  mapObservableStateResult,
  mapObservableStateResultEx,
  mapObservableChangeResult,
  mapObservableChangeResultEx,
  mergeObservableResult,

  -- *** Pending change helpers
  PendingChange,
  LastChange(..),
  updatePendingChange,
  initialPendingChange,
  initialPendingAndLastChange,
  replacingPendingChange,
  changeFromPending,

  -- *** Merging changes
  MergeChange(..),
  MaybeL(..),
  attachMergeObserver,
  attachMonoidMergeObserver,
  attachEvaluatedMergeObserver,

  -- * Identity observable (single value without partial updates)
  Observable(..),
  ToObservable,
  toObservable,
  readObservable,
  retrieveObservable,
  constObservable,
  throwExObservable,
  Void1,
  absurd1,
) where

import Control.Applicative
import Control.Monad.Catch.Pure (MonadThrow(..))
import Control.Monad.Except
import Data.Bifunctor (first)
import Data.Binary (Binary)
import Data.String (IsString(..))
import Data.Type.Equality ((:~:)(Refl))
import Data.Void (absurd)
import GHC.Records (HasField(..))
import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Fix
import Control.Monad.Catch (bracket)

-- * Generalized observables

type IsObservableCore :: LoadKind -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class IsObservableCore canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  {-# MINIMAL readObservable#, (attachObserver# | attachEvaluatedObserver#) #-}

  readObservable# ::
    a ->
    STMc NoRetry '[] (ObservableState canLoad (ObservableResult exceptions c) v)

  attachObserver#
    :: ObservableContainer c v
    => a
    -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachObserver# x callback = attachEvaluatedObserver# x \evaluatedChange ->
    callback case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveUpdate update -> ObservableChangeLiveUpdate case update of
        (EvaluatedUpdateReplace content) -> ObservableUpdateReplace content
        (EvaluatedUpdateDelta evaluated) -> ObservableUpdateDelta (toDelta @(ObservableResult exceptions c) evaluated)

  attachEvaluatedObserver#
    :: ObservableContainer c v
    => a
    -> (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachEvaluatedObserver# x callback =
    mfixTVar \var -> do
      (disposer, initial) <- attachObserver# x \change -> do
        cached <- readTVar var
        forM_ (applyObservableChange change cached) \(evaluatedChange, newCached) -> do
          writeTVar var newCached
          callback evaluatedChange

      pure ((disposer, initial), createObserverState initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: ObservableFunctor c => (v -> vb) -> a -> MappedObservable canLoad exceptions c vb
  mapObservable# f x = MappedObservable f x

  count# :: (ContainerCount c, ObservableContainer c v) => a -> Observable canLoad exceptions Int64
  count# x = mapObservableContent containerCount# x

  isEmpty# :: (ContainerCount c, ObservableContainer c v) => a -> Observable canLoad exceptions Bool
  isEmpty# x = mapObservableContent containerIsEmpty# x

type Bounds k = (Bound k, Bound k)

data Bound k
  = ExcludingBound k
  | IncludingBound k
  | NoBound

data Selector k
  = Min
  | Max
  | Key k

evaluateObservable :: (IsObservableCore canLoad exceptions c v a, ObservableContainer c v) => a -> Observable canLoad exceptions (c v)
evaluateObservable x = toObservable (EvaluatedObservableCore x)

mapObservableContent
  :: (IsObservableCore canLoad exceptions c v a, ObservableContainer c v)
  => (c v -> va)
  -> a
  -> Observable canLoad exceptions va
mapObservableContent f x = Observable (ObservableT (mapObservable# f (evaluateObservable x)))

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data LoadKind = Load | NoLoad
#else
data LoadKind = Load | NoLoad
type Load = 'Load
type NoLoad = 'NoLoad
#endif

absurdLoad :: Load ~ NoLoad => a
absurdLoad = unreachableCodePath


data ObservableT canLoad exceptions c v
  = forall a. (IsObservableCore canLoad exceptions c v a, ContainerConstraint canLoad exceptions c v a) => ObservableT a

instance IsObservableCore canLoad exceptions c v (ObservableT canLoad exceptions c v) where
  readObservable# (ObservableT x) = readObservable# x
  attachObserver# (ObservableT x) = attachObserver# x
  attachEvaluatedObserver# (ObservableT x) = attachEvaluatedObserver# x
  isCachedObservable# (ObservableT x) = isCachedObservable# x
  mapObservable# f (ObservableT x) = mapObservable# f x
  count# (ObservableT x) = count# x
  isEmpty# (ObservableT x) = isEmpty# x

type ToObservableT :: LoadKind -> [Type] -> (Type -> Type) -> Type -> Type -> Constraint
class ToObservableT canLoad exceptions c v a | a -> canLoad, a -> exceptions, a -> c, a -> v where
  toObservableT :: a -> ObservableT canLoad exceptions c v

instance ToObservableT canLoad exceptions c v (ObservableT canLoad exceptions c v) where
  toObservableT = id

retrieveObservableT ::
  forall canLoad exceptions c v.
  ObservableContainer c v =>
  ObservableT canLoad exceptions c v ->
  IO (c v)
retrieveObservableT fx = do
  var <- newTVarIO Nothing
  bracket
    (atomicallyC (attachObserver# fx (callback var)))
    (atomicallyC . disposeTSimpleDisposer . fst)
    \(_, initial) -> do
      unwrapObservableResultIO =<< case initial of
        ObservableStateLive initialResult -> pure initialResult
        ObservableStateLoading -> atomically (maybe retry pure =<< readTVar var)
  where
    -- Result is only used when observer is in LoadingCleared state
    callback ::
      TVar (Maybe (ObservableResult exceptions c v)) ->
      ObservableChange canLoad (ObservableResult exceptions c) v ->
      STMc NoRetry '[] ()
    callback var (ObservableChangeLiveReplace content) = do
      readTVar var >>= \case
        Just _ -> pure () -- Already received a value
        Nothing -> writeTVar var (Just content)
    callback _ _ = pure ()

readObservableT ::
  forall exceptions c v m a.
  (ToObservableT NoLoad exceptions c v a, MonadSTMc NoRetry exceptions m) =>
  a -> m (c v)
readObservableT fx = liftSTMc @NoRetry @exceptions do
  liftSTMc @NoRetry @'[] (readObservable# (toObservableT fx)) >>=
    \(ObservableStateLive result) -> unwrapObservableResult result


type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type ContainerConstraint (canLoad :: LoadKind) (exceptions :: [Type]) c v a :: Constraint
  type Delta c :: Type -> Type
  type EvaluatedDelta c v :: Type
  type instance EvaluatedDelta c v = (Delta c v, c v)

  -- | Enough information about a container to validate a delta.
  type DeltaContext c
  type instance DeltaContext _c = ()

  type ValidatedDelta c :: Type -> Type
  type instance ValidatedDelta c = Delta c

  applyDelta :: Delta c v -> c v -> c v
  mergeDelta :: ValidatedDelta c v -> Delta c v -> ValidatedDelta c v

  updateDeltaContext :: DeltaContext c -> Delta c v -> (ValidatedDelta c v, DeltaContext c)
  default updateDeltaContext :: (DeltaContext c ~ (), ValidatedDelta c v ~ Delta c v) => DeltaContext c -> Delta c v -> (ValidatedDelta c v, DeltaContext c)
  updateDeltaContext _ delta = (delta, ())

  toInitialDeltaContext :: c v -> DeltaContext c
  default toInitialDeltaContext :: DeltaContext c ~ () => c v -> DeltaContext c
  toInitialDeltaContext _ = ()

  toDelta :: EvaluatedDelta c v -> Delta c v

  -- | Law: @isJust (toEvaluatedDelta delta content) == isJust (splitDeltaAndContext (fst (updateDeltaContext ctx delta)))@
  toEvaluatedDelta :: Delta c v -> c v -> Maybe (EvaluatedDelta c v)
  default toEvaluatedDelta :: EvaluatedDelta c v ~ (Delta c v, c v) => Delta c v -> c v -> Maybe (EvaluatedDelta c v)
  toEvaluatedDelta delta content = Just (delta, content)

  contentFromEvaluatedDelta :: EvaluatedDelta c v -> c v

  -- | Split a 'ValidatedDelta' into its 'Delta' and 'DeltaContext'
  -- components.
  --
  -- Returns 'Nothing' if the delta has no effect given the current context.
  -- Please note that even a no-op or invalid delta will change a 'Loading'
  -- observable to 'Live'.
  splitDeltaAndContext :: ValidatedDelta c v -> Maybe (Delta c v, DeltaContext c)
  default splitDeltaAndContext ::
    (ValidatedDelta c v ~ Delta c v, DeltaContext c ~ ()) =>
    ValidatedDelta c v ->
    Maybe (Delta c v, DeltaContext c)
  splitDeltaAndContext delta = Just (delta, ())

-- | Test if the delta is empty, i.e. if applying the delta has no effect on the
-- container.
--
-- The result is based on 'splitDeltaAndContext'.
isEmptyDelta ::
  forall c v.
  ObservableContainer c v =>
  ValidatedDelta c v ->
  Bool
isEmptyDelta = isNothing . splitDeltaAndContext @c @v


mergeUpdate :: forall c v. ObservableContainer c v => ValidatedObservableUpdate c v -> ObservableUpdate c v -> ValidatedObservableUpdate c v
mergeUpdate _ (ObservableUpdateReplace content) = ValidatedObservableUpdateReplace content
mergeUpdate (ValidatedObservableUpdateReplace content) (ObservableUpdateDelta delta) =
  ValidatedObservableUpdateReplace (applyDelta @c delta content)
mergeUpdate (ValidatedObservableUpdateDelta old) (ObservableUpdateDelta new) =
  ValidatedObservableUpdateDelta (mergeDelta @c old new)

updateValidatedDelta :: forall c v. ObservableContainer c v => DeltaContext c -> ObservableUpdate c v -> ValidatedObservableUpdate c v
updateValidatedDelta _ (ObservableUpdateReplace content) = ValidatedObservableUpdateReplace content
updateValidatedDelta ctx (ObservableUpdateDelta delta) = ValidatedObservableUpdateDelta (fst (updateDeltaContext @c ctx delta))

instance ObservableContainer Identity v where
  type ContainerConstraint _canLoad _exceptions Identity v _a = ()
  type Delta Identity = Void1
  type EvaluatedDelta Identity v = Void
  applyDelta = absurd1
  mergeDelta _ new = new
  toInitialDeltaContext _ = ()
  toDelta = absurd
  toEvaluatedDelta = absurd1
  contentFromEvaluatedDelta = absurd

class ContainerCount c where
  containerCount# :: c v -> Int64
  containerIsEmpty# :: c v -> Bool

instance ContainerCount Identity where
  containerCount# _ = 1
  containerIsEmpty# _ = False

type Void1 :: Type -> Type
data Void1 a
  deriving Generic

absurd1 :: Void1 a -> b
absurd1 = \case {}

instance Functor Void1 where
  fmap _ = absurd1

instance Foldable Void1 where
  foldMap _ = absurd1
  foldr _ _ = absurd1

instance Traversable Void1 where
  traverse _ = absurd1

instance Show (Void1 a) where
  show = absurd1

instance Eq (Void1 a) where
  (==) = absurd1

instance Binary (Void1 a)


type ObservableFunctor c = (Functor c, Functor (Delta c), forall v. ObservableContainer c v)

type ObservableUpdate :: (Type -> Type) -> Type -> Type
data ObservableUpdate c v where
  ObservableUpdateReplace :: c v -> ObservableUpdate c v
  ObservableUpdateDelta :: Delta c v -> ObservableUpdate c v

deriving instance (Show (c v), Show (Delta c v)) => Show (ObservableUpdate c v)
deriving instance (Eq (c v), Eq (Delta c v)) => Eq (ObservableUpdate c v)

instance (Functor c, Functor (Delta c)) => Functor (ObservableUpdate c) where
  fmap fn (ObservableUpdateReplace x) = ObservableUpdateReplace (fn <$> x)
  fmap fn (ObservableUpdateDelta delta) = ObservableUpdateDelta (fn <$> delta)

instance (Foldable c, Traversable (Delta c)) => Foldable (ObservableUpdate c) where
  foldMap f (ObservableUpdateReplace x) = foldMap f x
  foldMap f (ObservableUpdateDelta delta) = foldMap f delta

instance (Traversable c, Traversable (Delta c)) => Traversable (ObservableUpdate c) where
  traverse f (ObservableUpdateReplace x) = ObservableUpdateReplace <$> traverse f x
  traverse f (ObservableUpdateDelta delta) = ObservableUpdateDelta <$> traverse f delta


type ValidatedObservableUpdate :: (Type -> Type) -> Type -> Type
data ValidatedObservableUpdate c v where
  ValidatedObservableUpdateReplace :: c v -> ValidatedObservableUpdate c v
  ValidatedObservableUpdateDelta :: ValidatedDelta c v -> ValidatedObservableUpdate c v

splitValidatedUpdate :: forall c v. ObservableContainer c v => ValidatedObservableUpdate c v -> Maybe (ObservableUpdate c v, DeltaContext c)
splitValidatedUpdate (ValidatedObservableUpdateReplace content) =
  Just (ObservableUpdateReplace content, toInitialDeltaContext content)
splitValidatedUpdate (ValidatedObservableUpdateDelta deltaWithContext) =
  first ObservableUpdateDelta <$> splitDeltaAndContext @c deltaWithContext


type EvaluatedUpdate :: (Type -> Type) -> Type -> Type
data EvaluatedUpdate c v where
  EvaluatedUpdateReplace :: c v -> EvaluatedUpdate c v
  EvaluatedUpdateDelta :: EvaluatedDelta c v -> EvaluatedUpdate c v

pattern EvaluatedUpdateOk :: EvaluatedUpdate c v -> EvaluatedUpdate (ObservableResult exceptions c) v
pattern EvaluatedUpdateOk update <- (evaluatedUpdateIsOk -> Just update) where
  EvaluatedUpdateOk (EvaluatedUpdateReplace x) = EvaluatedUpdateReplace (ObservableResultOk x)
  EvaluatedUpdateOk (EvaluatedUpdateDelta delta) = EvaluatedUpdateDelta delta

pattern EvaluatedUpdateThrow :: Ex exceptions -> EvaluatedUpdate (ObservableResult exceptions c) v
pattern EvaluatedUpdateThrow ex = (EvaluatedUpdateReplace (ObservableResultEx ex))

evaluatedUpdateIsOk :: EvaluatedUpdate (ObservableResult exceptions c) v -> Maybe (EvaluatedUpdate c v)
evaluatedUpdateIsOk (EvaluatedUpdateReplace (ObservableResultOk x)) = Just (EvaluatedUpdateReplace x)
evaluatedUpdateIsOk (EvaluatedUpdateReplace (ObservableResultEx _)) = Nothing
evaluatedUpdateIsOk (EvaluatedUpdateDelta delta) = Just (EvaluatedUpdateDelta delta)

{-# COMPLETE EvaluatedUpdateOk, EvaluatedUpdateThrow #-}

instance ObservableContainer c v => HasField "content" (EvaluatedUpdate c v) (c v) where
  getField (EvaluatedUpdateReplace content) = content
  getField (EvaluatedUpdateDelta delta) = contentFromEvaluatedDelta delta

instance ObservableContainer c v => HasField "notEvaluated" (EvaluatedUpdate c v) (ObservableUpdate c v) where
  getField (EvaluatedUpdateReplace content) = ObservableUpdateReplace content
  getField (EvaluatedUpdateDelta delta) = ObservableUpdateDelta (toDelta @c delta)

type ObservableChange :: LoadKind -> (Type -> Type) -> Type -> Type
data ObservableChange canLoad c v where
  ObservableChangeLoadingClear :: ObservableChange Load c v
  ObservableChangeLoadingUnchanged :: ObservableChange Load c v
  ObservableChangeLiveUnchanged :: ObservableChange Load c v
  ObservableChangeLiveUpdate :: ObservableUpdate c v -> ObservableChange canLoad c v

pattern ObservableChangeLiveReplace :: c v -> ObservableChange canLoad c v
pattern ObservableChangeLiveReplace content = ObservableChangeLiveUpdate (ObservableUpdateReplace content)

pattern ObservableChangeLiveDelta :: Delta c v -> ObservableChange canLoad c v
pattern ObservableChangeLiveDelta delta = ObservableChangeLiveUpdate (ObservableUpdateDelta delta)

{-# COMPLETE
  ObservableChangeLoadingClear,
  ObservableChangeLoadingUnchanged,
  ObservableChangeLiveUnchanged,
  ObservableChangeLiveReplace,
  ObservableChangeLiveDelta
  #-}

deriving instance (Show (c v), Show (Delta c v)) => Show (ObservableChange canLoad c v)
deriving instance (Eq (c v), Eq (Delta c v)) => Eq (ObservableChange canLoad c v)

instance (Functor c, Functor (Delta c)) => Functor (ObservableChange canLoad c) where
  fmap _fn ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  fmap _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
  fmap _fn ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  fmap fn (ObservableChangeLiveUpdate update) = ObservableChangeLiveUpdate (fn <$> update)

instance (Foldable c, Traversable (Delta c)) => Foldable (ObservableChange canLoad c) where
  foldMap f (ObservableChangeLiveUpdate update) = foldMap f update
  foldMap _ _ = mempty

instance (Traversable c, Traversable (Delta c)) => Traversable (ObservableChange canLoad c) where
  traverse _fn ObservableChangeLoadingUnchanged = pure ObservableChangeLoadingUnchanged
  traverse _fn ObservableChangeLoadingClear = pure ObservableChangeLoadingClear
  traverse _fn ObservableChangeLiveUnchanged = pure ObservableChangeLiveUnchanged
  traverse f (ObservableChangeLiveUpdate update) = ObservableChangeLiveUpdate <$> traverse f update

mapObservableChange :: (ca va -> c v) -> (Delta ca va -> Delta c v) -> ObservableChange canLoad ca va -> ObservableChange canLoad c v
mapObservableChange _ _ ObservableChangeLoadingClear = ObservableChangeLoadingClear
mapObservableChange _ _ ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
mapObservableChange _ _ ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
mapObservableChange fc _fd (ObservableChangeLiveReplace content) = ObservableChangeLiveReplace (fc content)
mapObservableChange _fc fd (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fd delta)

mapObservableChangeResult :: (c va -> c v) -> (Delta c va -> Delta c v) -> ObservableChange canLoad (ObservableResult exceptions c) va -> ObservableChange canLoad (ObservableResult exceptions c) v
mapObservableChangeResult fc = mapObservableChange (mapObservableResult fc)

mapObservableChangeResultEx :: (Ex ea -> Ex eb) -> ObservableChange canLoad (ObservableResult ea c) v -> ObservableChange canLoad (ObservableResult eb c) v
mapObservableChangeResultEx _ ObservableChangeLoadingClear = ObservableChangeLoadingClear
mapObservableChangeResultEx _ ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
mapObservableChangeResultEx _ ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
mapObservableChangeResultEx fn (ObservableChangeLiveUpdate update) = ObservableChangeLiveUpdate case update of
  ObservableUpdateReplace (ObservableResultOk content) -> ObservableUpdateReplace (ObservableResultOk content)
  ObservableUpdateReplace (ObservableResultEx ex) -> ObservableUpdateReplace (ObservableResultEx (fn ex))
  (ObservableUpdateDelta delta) -> ObservableUpdateDelta delta


type EvaluatedObservableChange :: LoadKind -> (Type -> Type) -> Type -> Type
data EvaluatedObservableChange canLoad c v where
  EvaluatedObservableChangeLoadingUnchanged :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLoadingClear :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLiveUnchanged :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLiveUpdate :: EvaluatedUpdate c v -> EvaluatedObservableChange canLoad c v

{-# COMPLETE ObservableStateLiveOk, ObservableStateLiveEx, ObservableStateLoading #-}

pattern ObservableStateLiveOk :: forall canLoad exceptions c v. c v -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveOk content = ObservableStateLive (ObservableResultOk content)

pattern ObservableStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveEx ex = ObservableStateLive (ObservableResultEx ex)

type ObservableState :: LoadKind -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: c v -> ObservableState canLoad c v

deriving instance Show (c v) => Show (ObservableState canLoad c v)
deriving instance Eq (c v) => Eq (ObservableState canLoad c v)

instance IsObservableCore canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v) where
  readObservable# = pure
  attachObserver# x _callback = pure (mempty, x)
  isCachedObservable# _ = True
  count# x = constObservable (mapObservableStateResult (Identity . containerCount#) x)
  isEmpty# x = constObservable (mapObservableStateResult (Identity . containerIsEmpty#) x)

instance (ObservableContainer c v, ContainerConstraint canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v)) => ToObservableT canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v) where
  toObservableT = ObservableT

instance HasField "loading" (ObservableState canLoad c v) (Loading canLoad) where
  getField ObservableStateLoading = Loading
  getField (ObservableStateLive _) = Live

mapObservableState :: (cp vp -> c v) -> ObservableState canLoad cp vp -> ObservableState canLoad c v
mapObservableState _fn ObservableStateLoading = ObservableStateLoading
mapObservableState fn (ObservableStateLive content) = ObservableStateLive (fn content)

mergeObservableState :: (ca va -> cb vb -> c v) -> ObservableState canLoad ca va -> ObservableState canLoad cb vb -> ObservableState canLoad c v
mergeObservableState fn (ObservableStateLive x) (ObservableStateLive y) = ObservableStateLive (fn x y)
mergeObservableState _fn ObservableStateLoading _ = ObservableStateLoading
mergeObservableState _fn _ ObservableStateLoading = ObservableStateLoading

instance Functor c => Functor (ObservableState canLoad c) where
  fmap _fn ObservableStateLoading = ObservableStateLoading
  fmap fn (ObservableStateLive content) = ObservableStateLive (fn <$> content)

instance Applicative c => Applicative (ObservableState canLoad c) where
  pure x = ObservableStateLive (pure x)
  liftA2 fn (ObservableStateLive fx) (ObservableStateLive fy) =
    ObservableStateLive (liftA2 fn fx fy)
  liftA2 _fn ObservableStateLoading _ = ObservableStateLoading
  liftA2 _fn _ ObservableStateLoading = ObservableStateLoading

instance Foldable c => Foldable (ObservableState canLoad c) where
  foldMap _fn ObservableStateLoading = mempty
  foldMap fn (ObservableStateLive x) = foldMap fn x
  foldr _ i ObservableStateLoading = i
  foldr fn i (ObservableStateLive x) = foldr fn i x

instance Traversable c => Traversable (ObservableState canLoad c) where
  traverse _fn ObservableStateLoading = pure ObservableStateLoading
  traverse fn (ObservableStateLive x) = ObservableStateLive <$> traverse fn x
  sequenceA ObservableStateLoading = pure ObservableStateLoading
  sequenceA (ObservableStateLive x) = ObservableStateLive <$> sequenceA x

type ObserverState :: LoadKind -> (Type -> Type) -> Type -> Type
data ObserverState canLoad c v where
  ObserverStateLoadingCleared :: ObserverState Load c v
  ObserverStateLoadingCached :: c v -> ObserverState Load c v
  ObserverStateLive :: c v -> ObserverState canLoad c v

{-# COMPLETE ObserverStateLoading, ObserverStateLive #-}

pattern ObserverStateLoading :: () => (canLoad ~ Load) => ObserverState canLoad c v
pattern ObserverStateLoading <- ((.loading) -> Loading)

{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoading #-}
{-# COMPLETE ObserverStateLiveOk, ObserverStateLiveEx, ObserverStateLoadingCached, ObserverStateLoadingCleared #-}

pattern ObserverStateLiveOk :: forall canLoad exceptions c v. c v -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveOk content = ObserverStateLive (ObservableResultOk content)

pattern ObserverStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObserverState canLoad (ObservableResult exceptions c) v
pattern ObserverStateLiveEx ex = ObserverStateLive (ObservableResultEx ex)

instance Foldable c => Foldable (ObserverState canLoad c) where
  foldMap fn ObserverStateLoadingCleared = mempty
  foldMap fn (ObserverStateLoadingCached x) = foldMap fn x
  foldMap fn (ObserverStateLive x) = foldMap fn x
  foldr _ initial ObserverStateLoadingCleared = initial
  foldr fn i (ObserverStateLoadingCached x) = foldr fn i x
  foldr fn i (ObserverStateLive x) = foldr fn i x

instance HasField "loading" (ObserverState canLoad c v) (Loading canLoad) where
  getField ObserverStateLoadingCleared = Loading
  getField ObserverStateLoading = Loading
  getField (ObserverStateLive _) = Live

instance HasField "maybe" (ObserverState canLoad c v) (Maybe (c v)) where
  getField ObserverStateLoadingCleared = Nothing
  getField (ObserverStateLoadingCached cache) = Just cache
  getField (ObserverStateLive evaluated) = Just evaluated

instance HasField "maybeL" (ObserverState canLoad c v) (MaybeL canLoad (c v)) where
  getField ObserverStateLoadingCleared = NothingL
  getField (ObserverStateLoadingCached cache) = JustL cache
  getField (ObserverStateLive evaluated) = JustL evaluated

instance ObservableContainer c v => HasField "context" (ObserverState canLoad c v) (ObserverContext canLoad c) where
  getField ObserverStateLoadingCleared = ObserverContextLoadingCleared
  getField (ObserverStateLoadingCached cache) = ObserverContextLoadingCached (toInitialDeltaContext cache)
  getField (ObserverStateLive state) = ObserverContextLive (toInitialDeltaContext state)

type ObserverContext :: LoadKind -> (Type -> Type) -> Type
data ObserverContext canLoad c where
  ObserverContextLoadingCleared :: ObserverContext Load c
  ObserverContextLoadingCached :: DeltaContext c -> ObserverContext Load c
  ObserverContextLive :: DeltaContext c -> ObserverContext canLoad c

updateObserverContext ::
  forall canLoad c v.
  ObservableContainer c v =>
  ObserverContext canLoad c ->
  ObservableChange canLoad c v ->
  ObserverContext canLoad c
updateObserverContext _ ObservableChangeLoadingClear = ObserverContextLoadingCleared
updateObserverContext ObserverContextLoadingCleared ObservableChangeLoadingUnchanged = ObserverContextLoadingCleared
updateObserverContext x@(ObserverContextLoadingCached _ctx) ObservableChangeLoadingUnchanged = x
updateObserverContext (ObserverContextLive ctx) ObservableChangeLoadingUnchanged = ObserverContextLoadingCached ctx
updateObserverContext ObserverContextLoadingCleared ObservableChangeLiveUnchanged = ObserverContextLoadingCleared
updateObserverContext (ObserverContextLoadingCached ctx) ObservableChangeLiveUnchanged = ObserverContextLive ctx
updateObserverContext x@(ObserverContextLive _ctx) ObservableChangeLiveUnchanged = x
updateObserverContext _ (ObservableChangeLiveReplace new) = ObserverContextLive (toInitialDeltaContext new)
updateObserverContext ObserverContextLoadingCleared (ObservableChangeLiveDelta _delta) =
  ObserverContextLoadingCleared
updateObserverContext (ObserverContextLoadingCached deltaContext) (ObservableChangeLiveDelta delta) =
  ObserverContextLive (snd (updateDeltaContext @c deltaContext delta))
updateObserverContext (ObserverContextLive deltaContext) (ObservableChangeLiveDelta delta) =
  ObserverContextLive (snd (updateDeltaContext @c deltaContext delta))


type Loading :: LoadKind -> Type
data Loading canLoad where
  Live :: Loading canLoad
  Loading :: Loading Load

deriving instance Show (Loading canLoad)
deriving instance Eq (Loading canLoad)
deriving instance Ord (Loading canLoad)

instance Semigroup (Loading canLoad) where
  Live <> Live = Live
  Loading <> _ = Loading
  _ <> Loading = Loading

applyObservableUpdate
  :: ObservableContainer c v
  => ObservableUpdate c v
  -> c v
  -> c v
applyObservableUpdate (ObservableUpdateReplace new) _ = new
applyObservableUpdate (ObservableUpdateDelta delta) old = applyDelta delta old

applyObservableChange
  :: ObservableContainer c v
  => ObservableChange canLoad c v
  -> ObserverState canLoad c v
  -> Maybe (EvaluatedObservableChange canLoad c v, ObserverState canLoad c v)
applyObservableChange ObservableChangeLoadingClear ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingClear _ = Just (EvaluatedObservableChangeLoadingClear, ObserverStateLoadingCleared)
applyObservableChange ObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyObservableChange ObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (EvaluatedObservableChangeLoadingUnchanged, ObserverStateLoadingCached state)
applyObservableChange ObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (EvaluatedObservableChangeLiveUnchanged, ObserverStateLive state)
applyObservableChange ObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing

applyObservableChange (ObservableChangeLiveReplace content) _ =
  Just (EvaluatedObservableChangeLiveUpdate (EvaluatedUpdateReplace content), ObserverStateLive content)

applyObservableChange (ObservableChangeLiveDelta _delta) ObserverStateLoadingCleared = Nothing
applyObservableChange (ObservableChangeLiveDelta delta) (ObserverStateCached _ old) = do
  new <- Just (applyDelta delta old)
  evaluated <- toEvaluatedDelta delta new
  Just (EvaluatedObservableChangeLiveUpdate (EvaluatedUpdateDelta evaluated), ObserverStateLive new)

applyEvaluatedObservableChange
  :: ObservableContainer c v
  => EvaluatedObservableChange canLoad c v
  -> ObserverState canLoad c v
  -> Maybe (ObserverState canLoad c v)
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear _ = Just ObserverStateLoadingCleared
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (ObserverStateLoadingCached state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (ObserverStateLive state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveUpdate (EvaluatedUpdateDelta _)) ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveUpdate evaluatedUpdate) _ = Just (ObserverStateLive (evaluatedUpdate.content))


createObserverState
  :: ObservableState canLoad c v
  -> ObserverState canLoad c v
createObserverState ObservableStateLoading = ObserverStateLoadingCleared
createObserverState (ObservableStateLive content) = ObserverStateLive content

toObservableState
  :: ObserverState canLoad c v
  -> ObservableState canLoad c v
toObservableState ObserverStateLoadingCleared = ObservableStateLoading
toObservableState (ObserverStateLoadingCached _) = ObservableStateLoading
toObservableState (ObserverStateLive content) = ObservableStateLive content

toInitialChange :: ObservableState canLoad c v -> ObservableChange canLoad c v
toInitialChange ObservableStateLoading = ObservableChangeLoadingClear
toInitialChange (ObservableStateLive x) = ObservableChangeLiveUpdate (ObservableUpdateReplace x)


pattern ObserverStateCached :: Loading canLoad -> c v -> ObserverState canLoad c v
pattern ObserverStateCached loading state <- (deconstructObserverStateCached -> Just (loading, state)) where
  ObserverStateCached = constructObserverStateCached
{-# COMPLETE ObserverStateCached, ObserverStateLoadingCleared #-}

deconstructObserverStateCached :: ObserverState canLoad c v -> Maybe (Loading canLoad, c v)
deconstructObserverStateCached ObserverStateLoadingCleared = Nothing
deconstructObserverStateCached (ObserverStateLoadingCached content) = Just (Loading, content)
deconstructObserverStateCached (ObserverStateLive content) = Just (Live, content)

constructObserverStateCached :: Loading canLoad -> c v -> ObserverState canLoad c v
constructObserverStateCached Live content = ObserverStateLive content
constructObserverStateCached Loading content = ObserverStateLoadingCached content


data MaybeL canLoad a where
  NothingL :: MaybeL Load a
  JustL :: a -> MaybeL canLoad a

fromMaybeL :: a -> MaybeL canLoad a -> a
fromMaybeL x NothingL = x
fromMaybeL _ (JustL x) = x


type PendingChange :: LoadKind -> (Type -> Type) -> Type -> Type
data PendingChange canLoad c v where
  PendingChangeLoadingClear :: PendingChange Load c v
  PendingChangeAlter :: Loading canLoad -> Either (DeltaContext c) (ValidatedObservableUpdate c v) -> PendingChange canLoad c v

type LastChange :: LoadKind -> Type
data LastChange canLoad where
  LastChangeLoadingCleared :: LastChange Load
  LastChangeLoading :: LastChange Load
  LastChangeLive :: LastChange canLoad

instance HasField "loading" (LastChange canLoad) (Loading canLoad) where
  getField LastChangeLoadingCleared = Loading
  getField LastChangeLoading = Loading
  getField LastChangeLive = Live

updatePendingChange :: forall canLoad c v. ObservableContainer c v => ObservableChange canLoad c v -> PendingChange canLoad c v -> PendingChange canLoad c v
updatePendingChange ObservableChangeLoadingClear _ = PendingChangeLoadingClear
updatePendingChange ObservableChangeLoadingUnchanged PendingChangeLoadingClear = PendingChangeLoadingClear
updatePendingChange ObservableChangeLiveUnchanged PendingChangeLoadingClear = PendingChangeLoadingClear
updatePendingChange ObservableChangeLoadingUnchanged (PendingChangeAlter _loading delta) = PendingChangeAlter Loading delta
updatePendingChange ObservableChangeLiveUnchanged (PendingChangeAlter _loading delta) = PendingChangeAlter Live delta
updatePendingChange (ObservableChangeLiveReplace content) _ =
  PendingChangeAlter Live (Right (ValidatedObservableUpdateReplace content))
updatePendingChange (ObservableChangeLiveDelta _delta) PendingChangeLoadingClear = PendingChangeLoadingClear
updatePendingChange (ObservableChangeLiveUpdate update) (PendingChangeAlter _loading (Right prevUpdate)) =
  let newUpdate = mergeUpdate @c prevUpdate update
  in PendingChangeAlter Live (Right newUpdate)
updatePendingChange (ObservableChangeLiveUpdate update) (PendingChangeAlter _loading (Left ctx)) =
  PendingChangeAlter Live (Right (updateValidatedDelta @c ctx update))

initialPendingChange :: ObservableContainer c v => ObservableState canLoad c v -> PendingChange canLoad c v
initialPendingChange ObservableStateLoading = PendingChangeLoadingClear
initialPendingChange (ObservableStateLive initial) = PendingChangeAlter Live (Left (toInitialDeltaContext initial))

replacingPendingChange :: ObservableState canLoad c v -> PendingChange canLoad c v
replacingPendingChange ObservableStateLoading = PendingChangeLoadingClear
replacingPendingChange (ObservableStateLive initial) = PendingChangeAlter Live (Right (ValidatedObservableUpdateReplace initial))

initialPendingAndLastChange :: ObservableContainer c v => ObservableState canLoad c v -> (PendingChange canLoad c v, LastChange canLoad)
initialPendingAndLastChange ObservableStateLoading =
  (PendingChangeLoadingClear, LastChangeLoadingCleared)
initialPendingAndLastChange (ObservableStateLive initial) =
  let ctx = toInitialDeltaContext initial
  in (PendingChangeAlter Live (Left ctx), LastChangeLive)


changeFromPending ::
  forall canLoad c v.
  ObservableContainer c v =>
  Loading canLoad ->
  PendingChange canLoad c v ->
  LastChange canLoad ->
  Maybe (ObservableChange canLoad c v, PendingChange canLoad c v, LastChange canLoad)
changeFromPending loading pendingChange lastChange = do
  (change, newPendingChange) <- changeFromPending' loading pendingChange lastChange
  pure (change, newPendingChange, updateLastChange change lastChange)
  where

    changeFromPending' :: Loading canLoad -> PendingChange canLoad c v -> LastChange canLoad -> Maybe (ObservableChange canLoad c v, PendingChange canLoad c v)
    -- Category: Changing to loading or already loading
    changeFromPending' _ PendingChangeLoadingClear LastChangeLoadingCleared = Nothing
    changeFromPending' _ PendingChangeLoadingClear _ = Just (ObservableChangeLoadingClear, PendingChangeLoadingClear)
    changeFromPending' _ x@(PendingChangeAlter Loading _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    changeFromPending' _ (PendingChangeAlter Loading _) LastChangeLoadingCleared = Nothing
    changeFromPending' _ (PendingChangeAlter Loading _) LastChangeLoading = Nothing
    changeFromPending' _ (PendingChangeAlter Live (Left _)) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _) LastChangeLoadingCleared = Nothing
    changeFromPending' Loading (PendingChangeAlter Live _) LastChangeLoading = Nothing
    changeFromPending' Loading x@(PendingChangeAlter Live _) LastChangeLive = Just (ObservableChangeLoadingUnchanged, x)
    -- Category: Changing to live or already live
    changeFromPending' Live x@(PendingChangeAlter Live (Left _)) LastChangeLoading = Just (ObservableChangeLiveUnchanged, x)
    changeFromPending' Live (PendingChangeAlter Live (Left _)) LastChangeLive = Nothing
    changeFromPending' Live x@(PendingChangeAlter Live (Right updateWC)) lc = do
      case splitValidatedUpdate updateWC of
        Just (update, ctx) -> Just (ObservableChangeLiveUpdate update, PendingChangeAlter Live (Left ctx))
        Nothing -> case lc of
          LastChangeLoading -> Just (ObservableChangeLiveUnchanged, x)
          LastChangeLive -> Nothing
          LastChangeLoadingCleared -> Nothing

    updateLastChange :: ObservableChange canLoad c v -> LastChange canLoad -> LastChange canLoad
    updateLastChange ObservableChangeLoadingClear _ = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged _ = LastChangeLoading
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLiveUnchanged _ = LastChangeLive
    -- Applying a Delta to a Cleared state is a no-op.
    updateLastChange (ObservableChangeLiveUpdate (ObservableUpdateDelta _)) LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange (ObservableChangeLiveUpdate _) _ = LastChangeLive


data MappedObservable canLoad exceptions c v = forall va a. IsObservableCore canLoad exceptions c va a => MappedObservable (va -> v) a

instance ObservableFunctor c => IsObservableCore canLoad exceptions c v (MappedObservable canLoad exceptions c v) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \change ->
      callback (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fn <<$>> readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    MappedObservable (f1 . f2) upstream
  count# (MappedObservable _ upstream) = count# upstream
  isEmpty# (MappedObservable _ upstream) = isEmpty# upstream


data EvaluatedObservableCore canLoad exceptions c v = forall a. IsObservableCore canLoad exceptions c v a => EvaluatedObservableCore a

instance ObservableContainer c v => ToObservableT canLoad exceptions Identity (c v) (EvaluatedObservableCore canLoad exceptions c v) where
  toObservableT = ObservableT

instance ObservableContainer c v => IsObservableCore canLoad exceptions Identity (c v) (EvaluatedObservableCore canLoad exceptions c v) where
  readObservable# (EvaluatedObservableCore observable) = mapObservableStateResult Identity <$> readObservable# observable
  attachEvaluatedObserver# (EvaluatedObservableCore observable) callback =
    mapObservableStateResult Identity <<$>> attachEvaluatedObserver# observable \evaluatedChange ->
      callback case evaluatedChange of
        EvaluatedObservableChangeLoadingClear -> EvaluatedObservableChangeLoadingClear
        EvaluatedObservableChangeLoadingUnchanged -> EvaluatedObservableChangeLoadingUnchanged
        EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
        EvaluatedObservableChangeLiveUpdate update ->
          let new = mapObservableResult Identity update.content
          in EvaluatedObservableChangeLiveUpdate (EvaluatedUpdateReplace new)

mapObservableStateResult :: (cp vp -> c v) -> ObservableState canLoad (ObservableResult exceptions cp) vp -> ObservableState canLoad (ObservableResult exceptions c) v
mapObservableStateResult _fn ObservableStateLoading = ObservableStateLoading
mapObservableStateResult _fn (ObservableStateLiveEx ex) = ObservableStateLiveEx ex
mapObservableStateResult fn (ObservableStateLiveOk content) = ObservableStateLiveOk (fn content)

mapObservableStateResultEx :: (Ex ea -> Ex eb) -> ObservableState canLoad (ObservableResult ea c) v -> ObservableState canLoad (ObservableResult eb c) v
mapObservableStateResultEx _fn ObservableStateLoading = ObservableStateLoading
mapObservableStateResultEx fn (ObservableStateLiveEx ex) = ObservableStateLiveEx (fn ex)
mapObservableStateResultEx _fn (ObservableStateLiveOk content) = ObservableStateLiveOk content


data LiftA2Observable l e c v = forall va vb a b. (IsObservableCore l e c va a, ObservableContainer c va, IsObservableCore l e c vb b, ObservableContainer c vb) => LiftA2Observable (va -> vb -> v) a b

instance (Applicative c, ObservableContainer c v, ContainerConstraint canLoad exceptions c v (LiftA2Observable canLoad exceptions c v)) => ToObservableT canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  toObservableT = ObservableT

instance (Applicative c, ObservableContainer c v) => IsObservableCore canLoad exceptions c v (LiftA2Observable canLoad exceptions c v) where
  readObservable# (LiftA2Observable fn fx fy) =
    liftA2 (liftA2 fn) (readObservable# fx) (readObservable# fy)

  attachObserver# (LiftA2Observable fn fx fy) =
    attachEvaluatedMergeObserver (liftA2 fn) fx fy


attachEvaluatedMergeObserver
  :: forall canLoad exceptions c v ca va cb vb a b.
  (IsObservableCore canLoad exceptions ca va a, IsObservableCore canLoad exceptions cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  => (ca va -> cb vb -> c v)
  -> a
  -> b
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachEvaluatedMergeObserver mergeState =
  attachMergeObserver mergeState fn fn2 clearFn clearFn
  where
    fn :: EvaluatedUpdate ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    fn _x _prev NothingL = Just MergeChangeClear
    fn (EvaluatedUpdateReplace x) _prev (JustL y) = Just (MergeChangeUpdate (ObservableUpdateReplace (mergeState x y)))
    fn (EvaluatedUpdateDelta x) _prev (JustL y) = Just (MergeChangeUpdate (ObservableUpdateReplace (mergeState (contentFromEvaluatedDelta x) y)))
    fn2 :: EvaluatedUpdate cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    fn2 _y _x NothingL = Just MergeChangeClear
    fn2 (EvaluatedUpdateReplace y) _prev (JustL x) = Just (MergeChangeUpdate (ObservableUpdateReplace (mergeState x y)))
    fn2 (EvaluatedUpdateDelta y) _prev (JustL x) = Just (MergeChangeUpdate (ObservableUpdateReplace (mergeState x (contentFromEvaluatedDelta y))))
    clearFn :: forall d e. canLoad :~: Load -> d -> e -> Maybe (MergeChange canLoad c v)
    clearFn Refl _ _ = Just MergeChangeClear


data MergeChange canLoad c v where
  MergeChangeClear :: MergeChange Load c v
  MergeChangeUpdate :: ObservableUpdate c v -> MergeChange canLoad c v


attachMergeObserver
  :: forall canLoad exceptions ca va cb vb c v a b.
  (IsObservableCore canLoad exceptions ca va a, IsObservableCore canLoad exceptions cb vb b, ObservableContainer ca va, ObservableContainer cb vb, ObservableContainer c v)
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (EvaluatedUpdate ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (EvaluatedUpdate cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a cleared LHS.
  -> (canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v))
  -- Function to create a delta from a cleared RHS.
  -> (canLoad :~: Load -> cb vb -> ca va -> Maybe (MergeChange canLoad c v))
  -- LHS observable input.
  -> a
  -- RHS observable input.
  -> b
  -- The remainder of the signature matches `attachObserver`, so it can be used
  -- as an implementation for it.
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachMergeObserver fullMergeFn leftFn rightFn clearLeftFn clearRightFn fx fy callback = do
  mfixTVar \leftState -> mfixTVar \rightState -> mfixTVar \state -> do
    (disposerX, stateX) <- attachEvaluatedObserver# fx (mergeCallback @canLoad @(ObservableResult exceptions c) leftState rightState state wrappedFullMergeFn wrappedLeftFn wrappedClearLeftFn callback)
    (disposerY, stateY) <- attachEvaluatedObserver# fy (mergeCallback @canLoad @(ObservableResult exceptions c) rightState leftState state (flip wrappedFullMergeFn) wrappedRightFn wrappedClearRightFn callback)
    let
      initialState = mergeObservableState wrappedFullMergeFn stateX stateY
      initialMergeState = initialPendingAndLastChange initialState
      initialLeftState = createObserverState stateX
      initialRightState = createObserverState stateY
    pure ((((disposerX <> disposerY, initialState), initialLeftState), initialRightState), initialMergeState)

  where
    wrappedFullMergeFn :: ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> ObservableResult exceptions c v
    wrappedFullMergeFn = mergeObservableResult fullMergeFn

    wrappedLeftFn :: EvaluatedUpdate (ObservableResult exceptions ca) va -> Maybe (ObservableResult exceptions ca va) -> MaybeL canLoad (ObservableResult exceptions cb vb) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception
    wrappedLeftFn (EvaluatedUpdateThrow ex) _ _ = Just (MergeChangeUpdate (ObservableUpdateReplace (ObservableResultEx ex)))

    -- RHS exception
    wrappedLeftFn (EvaluatedUpdateOk _update) _prevX (JustL (ObservableResultEx _ex)) = Nothing

    wrappedLeftFn (EvaluatedUpdateOk update) (Just (ObservableResultOk prevX)) (JustL (ObservableResultOk prevY)) = wrapMergeChange <$> leftFn update (Just prevX) (JustL prevY)
    wrappedLeftFn (EvaluatedUpdateOk update) (Just (ObservableResultOk prevX)) NothingL = wrapMergeChange <$> leftFn update (Just prevX) NothingL

    wrappedLeftFn (EvaluatedUpdateOk update) _ (JustL (ObservableResultOk prevY)) = wrapMergeChange <$> leftFn update Nothing (JustL prevY)
    wrappedLeftFn (EvaluatedUpdateOk update) _ NothingL = wrapMergeChange <$> leftFn update Nothing NothingL


    wrappedRightFn :: EvaluatedUpdate (ObservableResult exceptions cb) vb -> Maybe (ObservableResult exceptions cb vb) -> MaybeL canLoad (ObservableResult exceptions ca va) -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    -- LHS exception has priority over any RHS change
    wrappedRightFn _ _ (JustL (ObservableResultEx _)) = Nothing

    -- Otherwise RHS exception is chosen
    wrappedRightFn (EvaluatedUpdateThrow ex) _ _ = Just (MergeChangeUpdate (ObservableUpdateReplace (ObservableResultEx ex)))

    wrappedRightFn (EvaluatedUpdateOk update) (Just (ObservableResultOk prevY)) (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn update (Just prevY) (JustL x)
    wrappedRightFn (EvaluatedUpdateOk update) (Just (ObservableResultOk prevY)) NothingL = wrapMergeChange <$> rightFn update (Just prevY) NothingL

    wrappedRightFn (EvaluatedUpdateOk update) _ (JustL (ObservableResultOk x)) = wrapMergeChange <$> rightFn update Nothing (JustL x)
    wrappedRightFn (EvaluatedUpdateOk update) _ NothingL = wrapMergeChange <$> rightFn update Nothing NothingL

    wrappedClearLeftFn :: canLoad :~: Load -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearLeftFn Refl (ObservableResultOk prevX) (ObservableResultOk y) = wrapMergeChange <$> clearLeftFn Refl prevX y
    wrappedClearLeftFn Refl _ _ = Just MergeChangeClear

    wrappedClearRightFn :: canLoad :~: Load -> ObservableResult exceptions cb vb -> ObservableResult exceptions ca va -> Maybe (MergeChange canLoad (ObservableResult exceptions c) v)
    wrappedClearRightFn Refl (ObservableResultOk prevY) (ObservableResultOk x) = wrapMergeChange <$> clearRightFn Refl prevY x
    wrappedClearRightFn Refl _ _ = Just MergeChangeClear

    wrapMergeChange :: MergeChange canLoad c v -> MergeChange canLoad (ObservableResult exceptions c) v
    wrapMergeChange MergeChangeClear = MergeChangeClear
    wrapMergeChange (MergeChangeUpdate (ObservableUpdateReplace content)) = MergeChangeUpdate (ObservableUpdateReplace (ObservableResultOk content))
    wrapMergeChange (MergeChangeUpdate (ObservableUpdateDelta delta)) = MergeChangeUpdate (ObservableUpdateDelta delta)

mergeCallback
  :: forall canLoad c v ca va cb vb. (
    ObservableContainer c v,
    ObservableContainer ca va
  )
  => TVar (ObserverState canLoad ca va)
  -> TVar (ObserverState canLoad cb vb)
  -> TVar (PendingChange canLoad c v, LastChange canLoad)
  -> (ca va -> cb vb -> c v)
  -> (EvaluatedUpdate ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v))
  -> (canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v))
  -> (ObservableChange canLoad c v -> STMc NoRetry '[] ())
  -> EvaluatedObservableChange canLoad ca va -> STMc NoRetry '[] ()
mergeCallback ourStateVar otherStateVar mergeStateVar fullMergeFn fn clearFn callback inChange = do
  oldState <- readTVar ourStateVar
  forM_ (applyEvaluatedObservableChange inChange oldState) \state -> do
    writeTVar ourStateVar state
    mergeState@(_pending, last) <- readTVar mergeStateVar
    otherState <- readTVar otherStateVar
    case last of
      LastChangeLoadingCleared -> do
        case (state, otherState) of
          -- The only way to restore from a cleared result is a reinitialisation.
          (ObserverStateLive x, ObserverStateLive y) -> reinitialize x y
          -- No need to keep deltas, since the only way out of Cleared state is a reinitialization.
          _ -> pure ()
      _lastNotCleared -> do
        case inChange of
          EvaluatedObservableChangeLoadingClear -> case oldState.maybe of
            Just prev -> clearOur prev otherState.maybeL
            Nothing -> pure ()
          EvaluatedObservableChangeLoadingUnchanged -> sendPendingChange Loading mergeState
          EvaluatedObservableChangeLiveUnchanged -> sendPendingChange (state.loading <> otherState.loading) mergeState
          EvaluatedObservableChangeLiveUpdate update ->
            mapM_ (applyMergeChange otherState.loading) (fn update oldState.maybe otherState.maybeL)
  where
    reinitialize :: ca va -> cb vb -> STMc NoRetry '[] ()
    reinitialize x y = applyChange Live (ObservableChangeLiveUpdate (ObservableUpdateReplace (fullMergeFn x y)))

    clearOur :: canLoad ~ Load => ca va -> MaybeL Load (cb vb) -> STMc NoRetry '[] ()
    -- Both sides are cleared now
    clearOur _prev NothingL = applyChange Loading ObservableChangeLoadingClear
    clearOur prev (JustL other) = mapM_ (applyMergeChange Loading) (clearFn Refl prev other)

    applyMergeChange :: Loading canLoad -> MergeChange canLoad c v -> STMc NoRetry '[] ()
    applyMergeChange _loading MergeChangeClear = applyChange Loading ObservableChangeLoadingClear
    applyMergeChange loading (MergeChangeUpdate up) = applyChange loading (ObservableChangeLiveUpdate up)

    applyChange :: Loading canLoad -> ObservableChange canLoad c v -> STMc NoRetry '[] ()
    applyChange loading change = do
      (prevPending, lastChange) <- readTVar mergeStateVar
      let pending = updatePendingChange change prevPending
      writeTVar mergeStateVar (pending, lastChange)
      sendPendingChange loading (pending, lastChange)

    sendPendingChange :: Loading canLoad -> (PendingChange canLoad c v, LastChange canLoad) -> STMc NoRetry '[] ()
    sendPendingChange loading (prevPending, prevLast) = do
      forM_ (changeFromPending loading prevPending prevLast) \(change, pending, last) -> do
        writeTVar mergeStateVar (pending, last)
        callback change

attachMonoidMergeObserver
  :: forall canLoad exceptions c v ca va cb vb a b.
  (
    Monoid (ca va),
    Monoid (cb vb),
    IsObservableCore canLoad exceptions ca va a,
    IsObservableCore canLoad exceptions cb vb b,
    ObservableContainer ca va,
    ObservableContainer cb vb,
    ObservableContainer c v
  )
  -- Function to create the internal state during (re)initialisation.
  => (ca va -> cb vb -> c v)
  -- Function to create a delta from a LHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (ObservableUpdate ca va -> ca va -> cb vb -> Maybe (ObservableUpdate c v))
  -- Function to create a delta from a RHS delta. Returning `Nothing` can be
  -- used to signal a no-op.
  -> (ObservableUpdate cb vb -> cb vb -> ca va -> Maybe (ObservableUpdate c v))
  -- LHS observable input.
  -> a
  -- RHS observable input.
  -> b
  -- The remainder of the signature matches `attachObserver`, so it can be used
  -- as an implementation for it.
  -> (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
  -> STMc NoRetry '[] (TSimpleDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachMonoidMergeObserver fullMergeFn leftFn rightFn fx fy callback =
  attachMergeObserver fullMergeFn wrappedLeftFn wrappedRightFn clearLeftFn clearRightFn fx fy callback
  where

    wrappedLeftFn :: EvaluatedUpdate ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)
    wrappedLeftFn update x y = MergeChangeUpdate <$> leftFn update.notEvaluated (fromMaybe mempty x) (fromMaybeL mempty y)

    wrappedRightFn :: EvaluatedUpdate cb vb -> Maybe (cb vb) -> MaybeL canLoad (ca va) -> Maybe (MergeChange canLoad c v)
    wrappedRightFn update y x = MergeChangeUpdate <$> rightFn update.notEvaluated (fromMaybe mempty y) (fromMaybeL mempty x)

    clearLeftFn :: canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v)
    clearLeftFn _refl prev other = wrappedLeftFn (EvaluatedUpdateReplace mempty) (Just prev) (JustL other)

    clearRightFn :: canLoad :~: Load -> cb vb -> ca va -> Maybe (MergeChange canLoad c v)
    clearRightFn _refl prev other = wrappedRightFn (EvaluatedUpdateReplace mempty) (Just prev) (JustL other)



data BindState canLoad c v where
  -- LHS cleared
  BindStateDetached :: BindState Load c v
  -- RHS attached
  BindStateAttached
    :: Loading canLoad -- ^ is LHS loading
    -> TSimpleDisposer -- ^ RHS disposer
    -> (PendingChange canLoad c v, LastChange canLoad) -- ^ RHS pending change
    -> BindState canLoad c v


data BindObservable canLoad exceptions va b
  = BindObservable (Observable canLoad exceptions va) (ObservableResult exceptions Identity va -> b)

instance (IsObservableCore canLoad exceptions c v b, ObservableContainer c v) => IsObservableCore canLoad exceptions c v (BindObservable canLoad exceptions va b) where
  readObservable# (BindObservable fx fn) = do
    readObservable# fx >>= \case
      ObservableStateLoading -> pure ObservableStateLoading
      ObservableStateLive result -> readObservable# (fn result)

  attachObserver# (BindObservable fx fn) callback = do
    mfixTVar \var -> do

      (fxDisposer, initialX) <- attachObserver# fx \case
        ObservableChangeLoadingClear -> lhsClear var
        ObservableChangeLoadingUnchanged -> lhsSetLoading var Loading
        ObservableChangeLiveUnchanged -> lhsSetLoading var Live
        ObservableChangeLiveReplace x -> lhsReplace var x
        ObservableChangeLiveDelta delta -> absurd1 delta

      (initial, bindState) <- case initialX of
        ObservableStateLoading -> pure (ObservableStateLoading, BindStateDetached)
        ObservableStateLive x -> do
          (disposerY, initialY) <- attachObserver# (fn x) (rhsCallback var)
          pure (initialY, BindStateAttached Live disposerY (initialPendingAndLastChange initialY))

      rhsDisposer <- newUnmanagedTSimpleDisposer do
        readTVar var >>= \case
          (BindStateAttached _ disposer _) -> disposeTSimpleDisposer disposer
          _ -> pure ()
      -- This relies on the fact, that the left disposer is detached first to
      -- prevent race conditions.
      let disposer = fxDisposer <> rhsDisposer

      pure ((disposer, initial), bindState)

    where
      lhsClear
        :: canLoad ~ Load
        => TVar (BindState canLoad (ObservableResult exceptions c) v)
        -> STMc NoRetry '[] ()
      lhsClear var =
        readTVar var >>= \case
          (BindStateAttached _ disposer (_, last)) -> do
            disposeTSimpleDisposer disposer
            writeTVar var BindStateDetached
            case last of
              LastChangeLoadingCleared -> pure () -- was already cleared
              _ -> callback ObservableChangeLoadingClear
          BindStateDetached -> pure () -- lhs was already cleared

      lhsSetLoading
        :: TVar (BindState canLoad (ObservableResult exceptions c) v)
        -> Loading canLoad
        -> STMc NoRetry '[] ()
      lhsSetLoading var loading =
        readTVar var >>= \case
          BindStateAttached _oldLoading disposer (pending, last) ->
            writeAndSendPending var loading disposer pending last
          _ -> pure () -- LHS is cleared, so this is a no-op

      lhsReplace
        :: TVar (BindState canLoad (ObservableResult exceptions c) v)
        -> ObservableResult exceptions Identity va
        -> STMc NoRetry '[] ()
      lhsReplace var x = do
        readTVar var >>= \case
          BindStateAttached _loading disposer (_pending, last) -> do
            disposeTSimpleDisposer disposer
            (disposerY, initialY) <- attachObserver# (fn x) (rhsCallback var)
            let newPending = replacingPendingChange initialY
            writeAndSendPending var Live disposerY newPending last
          BindStateDetached -> do
            (disposerY, initialY) <- attachObserver# (fn x) (rhsCallback var)
            let newPending = replacingPendingChange initialY
            writeAndSendPending var Live disposerY newPending LastChangeLoadingCleared

      rhsCallback
        :: TVar (BindState canLoad (ObservableResult exceptions c) v)
        -> ObservableChange canLoad (ObservableResult exceptions c) v
        -> STMc NoRetry '[] ()
      rhsCallback var changeY = do
        readTVar var >>= \case
          BindStateAttached loading disposer (pending, last) -> do
            let newPending = updatePendingChange changeY pending
            writeAndSendPending var loading disposer newPending last
          _ -> pure () -- Bug. This can only happen due to law violations elsewhere: the callback was called after unsubscribing.

      writeAndSendPending
        :: TVar (BindState canLoad (ObservableResult exceptions c) v)
        -> Loading canLoad -- LHS loading state
        -> TSimpleDisposer
        -> PendingChange canLoad (ObservableResult exceptions c) v -- RHS pending change
        -> LastChange canLoad
        -> STMc NoRetry '[] ()
      writeAndSendPending var loading disposer pending last =
        case changeFromPending loading pending last of
          Nothing -> writeTVar var (BindStateAttached loading disposer (pending, last))
          Just (change, newPending, newLast) -> do
            writeTVar var (BindStateAttached loading disposer (newPending, newLast))
            callback change

bindObservableT
  :: (
    ObservableContainer c v,
    ContainerConstraint canLoad exceptions c v (BindObservable canLoad exceptions va (ObservableT canLoad exceptions c v)),
    ContainerConstraint canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v)
  )
  => Observable canLoad exceptions va -> (va -> ObservableT canLoad exceptions c v) -> ObservableT canLoad exceptions c v
bindObservableT fx fn = ObservableT (BindObservable fx rhsHandler)
    where
      rhsHandler (ObservableResultOk (Identity x)) = fn x
      rhsHandler (ObservableResultEx ex) = ObservableT (ObservableStateLiveEx ex)


instance IsObservableCore Load '[] Identity v (Future v) where
  readObservable# future = do
    peekFuture future <&> \case
      Nothing -> ObservableStateLoading
      Just value -> ObservableStateLive (ObservableResultOk (Identity value))

  attachObserver# future callback = do
    initial <- readOrAttachToFuture# future \value ->
      callback (ObservableChangeLiveUpdate (ObservableUpdateReplace (ObservableResultOk (Identity value))))
    pure case initial of
      Left disposer -> (disposer, ObservableStateLoading)
      Right value -> (mempty, ObservableStateLive (ObservableResultOk (Identity value)))

instance ToObservableT Load '[] Identity v (Future v) where
  toObservableT = ObservableT


instance IsObservableCore Load exceptions Identity v (FutureEx exceptions v) where
  readObservable# future = do
    peekFuture future <&> \case
      Nothing -> ObservableStateLoading
      Just (Left ex) -> ObservableStateLive (ObservableResultEx ex)
      Just (Right value) -> ObservableStateLive (ObservableResultOk (Identity value))

  attachObserver# future callback = do
    initial <- readOrAttachToFuture# (toFuture future) \result ->
      callback $ ObservableChangeLiveUpdate $ ObservableUpdateReplace $ case result of
        Left ex -> ObservableResultEx ex
        Right value -> ObservableResultOk (Identity value)
    pure case initial of
      Left disposer -> (disposer, ObservableStateLoading)
      Right (Right value) -> (mempty, ObservableStateLive (ObservableResultOk (Identity value)))
      Right (Left ex) -> (mempty, ObservableStateLive (ObservableResultEx ex))

instance ToObservableT Load exceptions Identity v (FutureEx exceptions v) where
  toObservableT = ObservableT



-- ** Observable Identity

type ToObservable canLoad exceptions v = ToObservableT canLoad exceptions Identity v

toObservable :: ToObservable canLoad exceptions v a => a -> Observable canLoad exceptions v
toObservable = Observable . toObservableT

readObservable ::
  forall exceptions v m a.
  MonadSTMc NoRetry exceptions m =>
  Observable NoLoad exceptions v ->
  m v
readObservable (Observable fx) = runIdentity <$> readObservableT fx

retrieveObservable ::
  forall canLoad exceptions v m a.
  MonadIO m =>
  Observable canLoad exceptions v ->
  m v
retrieveObservable (Observable fx) = liftIO do
  runIdentity <$> retrieveObservableT fx


type Observable :: LoadKind -> [Type] -> Type -> Type
newtype Observable canLoad exceptions v = Observable (ObservableT canLoad exceptions Identity v)

instance ToObservableT canLoad exceptions Identity v (Observable canLoad exceptions v) where
  toObservableT (Observable x) = ObservableT x

instance Functor (Observable canLoad exceptions) where
  fmap fn (Observable fx) = Observable (ObservableT (mapObservable# fn fx))

instance Applicative (Observable canLoad exceptions) where
  pure x = constObservable (pure x)
  liftA2 f (Observable x) (Observable y) = toObservable (LiftA2Observable f x y)

instance Monad (Observable canLoad exceptions) where
  fx >>= fn = Observable (ObservableT (BindObservable fx rhsHandler))
    where
      rhsHandler (ObservableResultOk (Identity x)) = fn x
      rhsHandler (ObservableResultEx ex) = constObservable (ObservableStateLiveEx ex)

instance IsString v => IsString (Observable canLoad exceptions v) where
  fromString x = constObservable (pure (fromString x))

instance Num v => Num (Observable canLoad exceptions v) where
  (+) = liftA2 (+)
  (-) = liftA2 (-)
  (*) = liftA2 (*)
  negate = fmap negate
  abs = fmap abs
  signum = fmap signum
  fromInteger x = pure (fromInteger x)

instance MonadThrowEx (Observable canLoad exceptions) where
  unsafeThrowEx ex = constObservable (ObservableStateLiveEx (unsafeToEx ex))

instance (Exception e, e :< exceptions) => Throw e (Observable canLoad exceptions) where
  throwC exception =
    constObservable (ObservableStateLiveEx (toEx @exceptions exception))

instance (SomeException :< exceptions) => MonadThrow (Observable canLoad exceptions) where
  throwM x = throwEx (toEx @'[SomeException] x)


instance IsObservableCore canLoad exceptions Identity v (Observable canLoad exceptions v) where
  readObservable# (Observable x) = readObservable# x
  attachObserver# (Observable x) = attachObserver# x
  attachEvaluatedObserver# (Observable x) = attachEvaluatedObserver# x
  isCachedObservable# (Observable x) = isCachedObservable# x
  mapObservable# f (Observable x) = mapObservable# f x
  count# (Observable x) = count# x
  isEmpty# (Observable x) = isEmpty# x

constObservable :: ObservableState canLoad (ObservableResult exceptions Identity) v -> Observable canLoad exceptions v
constObservable state = Observable (ObservableT state)

-- | Can be used instead of `throwEx` when the exception list cannot be
-- evaluated at compile time.
throwExObservable :: Ex exceptions -> Observable canLoad exceptions v
throwExObservable = unsafeThrowEx . exToException


-- ** Exception wrapper

type ObservableResult :: [Type] -> (Type -> Type) -> Type -> Type
data ObservableResult exceptions c v
  = ObservableResultOk (c v)
  | ObservableResultEx (Ex exceptions)

deriving instance Show (c v) => Show (ObservableResult exceptions c v)
deriving instance (Eq (c v), Eq (Ex exceptions)) => Eq (ObservableResult exceptions c v)

instance Functor c => Functor (ObservableResult exceptions c) where
  fmap fn (ObservableResultOk content) = ObservableResultOk (fn <$> content)
  fmap _fn (ObservableResultEx ex) = ObservableResultEx ex

instance Applicative c => Applicative (ObservableResult exceptions c) where
  pure x = ObservableResultOk (pure x)
  liftA2 _fn (ObservableResultEx ex) _fy = ObservableResultEx ex
  liftA2 _fn _fx (ObservableResultEx ex) = ObservableResultEx ex
  liftA2 fn (ObservableResultOk fx) (ObservableResultOk fy) = ObservableResultOk (liftA2 fn fx fy)

instance Foldable c => Foldable (ObservableResult exceptions c) where
  foldMap f (ObservableResultOk x) = foldMap f x
  foldMap _f (ObservableResultEx _ex) = mempty

instance Traversable c => Traversable (ObservableResult exceptions c) where
  traverse f (ObservableResultOk x) = ObservableResultOk <$> traverse f x
  traverse _f (ObservableResultEx ex) = pure (ObservableResultEx ex)

unwrapObservableResult :: ObservableResult exceptions c v -> STMc canRetry exceptions (c v)
unwrapObservableResult (ObservableResultOk result) = pure result
unwrapObservableResult (ObservableResultEx ex) = throwExSTMc ex

unwrapObservableResultIO :: ObservableResult exceptions c v -> IO (c v)
unwrapObservableResultIO (ObservableResultOk result) = pure result
unwrapObservableResultIO (ObservableResultEx ex) = throwM (exToException ex)

mapObservableResult :: (ca va -> cb vb) -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb
mapObservableResult fn (ObservableResultOk result) = ObservableResultOk (fn result)
mapObservableResult _fn (ObservableResultEx ex) = ObservableResultEx ex

mergeObservableResult :: (ca va -> cb vb -> c v) -> ObservableResult exceptions ca va -> ObservableResult exceptions cb vb -> ObservableResult exceptions c v
mergeObservableResult fn (ObservableResultOk x) (ObservableResultOk y) = ObservableResultOk (fn x y)
mergeObservableResult _fn (ObservableResultEx ex) _ = ObservableResultEx ex
mergeObservableResult _fn _ (ObservableResultEx ex) = ObservableResultEx ex

type ValidatedResultDelta :: (Type -> Type) -> Type -> Type
data ValidatedResultDelta c v
  = ResultDeltaValid (ValidatedDelta c v)
  | ResultDeltaInvalid

instance Functor (ValidatedDelta c) => Functor (ValidatedResultDelta c) where
  fmap fn (ResultDeltaValid fx) = ResultDeltaValid (fmap fn fx)
  fmap _fn ResultDeltaInvalid = ResultDeltaInvalid

instance Foldable (ValidatedDelta c) => Foldable (ValidatedResultDelta c) where
  foldMap fn (ResultDeltaValid fx) = foldMap fn fx
  foldMap _fn ResultDeltaInvalid = mempty
  foldr fn i (ResultDeltaValid fx) = foldr fn i fx
  foldr _fn i ResultDeltaInvalid = i

instance Traversable (ValidatedDelta c) => Traversable (ValidatedResultDelta c) where
  traverse fn (ResultDeltaValid fx) = ResultDeltaValid <$> traverse fn fx
  traverse _fn ResultDeltaInvalid = pure ResultDeltaInvalid

instance ObservableContainer c v => ObservableContainer (ObservableResult exceptions c) v where
  type ContainerConstraint canLoad exceptions (ObservableResult exceptions c) v a = ContainerConstraint canLoad exceptions c v a
  type Delta (ObservableResult exceptions c) = Delta c
  type EvaluatedDelta (ObservableResult exceptions c) v = EvaluatedDelta c v
  type instance DeltaContext (ObservableResult exceptions c) = Maybe (DeltaContext c)
  type instance ValidatedDelta (ObservableResult exceptions c) = ValidatedResultDelta c
  applyDelta delta (ObservableResultOk content) = ObservableResultOk (applyDelta @c delta content)
  -- NOTE This rejects deltas that are applied to an exception state. Beware
  -- that regardeless of this fact this still does count as a valid delta
  -- application, so it won't prevent the state transition from Loading to Live.
  applyDelta _delta x@(ObservableResultEx _ex) = x
  mergeDelta (ResultDeltaValid old) new = ResultDeltaValid (mergeDelta @c old new)
  mergeDelta ResultDeltaInvalid _new = ResultDeltaInvalid
  updateDeltaContext (Just ctx) delta =
    let (x, y) = updateDeltaContext @c ctx delta
    in (ResultDeltaValid x, Just y)
  updateDeltaContext Nothing _delta = (ResultDeltaInvalid, Nothing)
  toInitialDeltaContext (ObservableResultOk initial) = Just (toInitialDeltaContext initial)
  toInitialDeltaContext (ObservableResultEx _) = Nothing
  toDelta = toDelta @c
  toEvaluatedDelta delta (ObservableResultOk content) = toEvaluatedDelta delta content
  toEvaluatedDelta _delta (ObservableResultEx _ex) = Nothing
  contentFromEvaluatedDelta delta = ObservableResultOk (contentFromEvaluatedDelta delta)
  splitDeltaAndContext (ResultDeltaValid innerDelta) =
    Just <<$>> splitDeltaAndContext @c innerDelta
  splitDeltaAndContext ResultDeltaInvalid = Nothing
