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
  ObservableChange(..),
  mapObservableChange,
  ValidatedChange(..),
  validateChange,
  EvaluatedObservableChange(..),
  contentFromEvaluatedDelta,
  ObservableState(.., ObservableStateLiveOk, ObservableStateLiveEx),
  mapObservableState,
  mergeObservableState,
  ObserverState(.., ObserverStateLoading, ObserverStateLiveOk, ObserverStateLiveEx),
  createObserverState,
  toObservableState,
  applyObservableChange,
  applyEvaluatedObservableChange,
  toReplacingChange,
  ObserverContext(..),
  updateObserverContext,
  ObservableFunctor,

  ObservableUpdate(..),
  observableUpdateToChange,
  ValidatedUpdate(..),
  mergeValidatedUpdate,
  validatedUpdateToContext,
  unvalidatedUpdate,
  EvaluatedUpdate(.., EvaluatedUpdateOk, EvaluatedUpdateThrow),

  MappedObservable(..),
  BindObservable(..),
  bindObservableT,

  -- *** Query
  Selector(..),
  Bounds,
  Bound(..),

  -- *** Exception wrapper container
  ObservableResult(.., ObservableResultTrivial),
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
  attachContextMergeObserver,
  attachEvaluatedMergeObserver,
  attachDeltaRemappingObserver,

  -- * Identity observable (single value without partial updates)
  Observable(..),
  ToObservable,
  toObservable,
  readObservable,
  retrieveObservable,
  constObservable,
  throwExObservable,
  catchObservable,
  catchAllObservable,
  attachSimpleObserver,
  skipUpdateIfEqual,
  Void1,
  absurd1,

  -- ** High-level observe wrapper
  observeWith,
  observeBlocking,
) where

import Control.Applicative
import Control.Monad.Catch (MonadThrow(..), MonadCatch(..), bracket, fromException, MonadMask)
import Data.Binary (Binary)
import Data.String (IsString(..))
import Data.Type.Equality ((:~:)(Refl))
import GHC.Records (HasField(..))
import Quasar.Disposer
import Quasar.Future
import Quasar.Prelude
import Quasar.Utils.Fix

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
    -> STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachObserver# x callback = attachEvaluatedObserver# x \evaluatedChange ->
    callback case evaluatedChange of
      EvaluatedObservableChangeLoadingClear -> ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveReplace content -> ObservableChangeLiveReplace content
      EvaluatedObservableChangeLiveDelta (delta, _) -> ObservableChangeLiveDelta delta

  attachEvaluatedObserver#
    :: ObservableContainer c v
    => a
    -> (EvaluatedObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ())
    -> STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
  attachEvaluatedObserver# x callback =
    mfixTVar \var -> do
      (disposer, initial) <- attachObserver# x \change -> do
        cached <- readTVar var
        forM_ (applyObservableChange change cached) \(evaluatedChange, newCached) -> do
          writeTVar var newCached
          callback evaluatedChange

      pure ((disposer, initial), createObserverState initial)

  isSharedObservable# :: a -> Bool
  isSharedObservable# _ = False

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
  isSharedObservable# (ObservableT x) = isSharedObservable# x
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
    (atomicallyC . disposeTDisposer . fst)
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

type EvaluatedDelta :: (Type -> Type) -> Type -> Type
type EvaluatedDelta c v = (Delta c v, c v)

contentFromEvaluatedDelta :: EvaluatedDelta c v -> c v
contentFromEvaluatedDelta (_, content) = content

-- | Law: @isJust (toEvaluatedDelta delta content) == isJust (validateDelta (toDeltaContext content) delta)@
toEvaluatedDelta :: Delta c v -> c v -> Maybe (EvaluatedDelta c v)
--default toEvaluatedDelta :: EvaluatedDelta c v ~ (Delta c v, c v) => Delta c v -> c v -> Maybe (EvaluatedDelta c v)
toEvaluatedDelta delta content = Just (delta, content)

type ObservableContainer :: (Type -> Type) -> Type -> Constraint
class ObservableContainer c v where
  type ContainerConstraint (canLoad :: LoadKind) (exceptions :: [Type]) c v a :: Constraint
  type instance ContainerConstraint _canLoad _exceptions _c _v _a = ()

  type Delta c :: Type -> Type

  -- | Enough information about a container to validate a delta.
  type DeltaContext c
  type instance DeltaContext _c = ()

  type ValidatedDelta c :: Type -> Type
  type instance ValidatedDelta c = Delta c

  -- | Apply a delta to a container.
  --
  -- TODO swap delta and state arguments
  --
  -- Law: When the result is `Nothing`, validateDelta the delta must return
  -- Nothing as well for the same inputs.
  applyDelta :: Delta c v -> c v -> Maybe (c v)

  -- | Validate a delta. A validated delta may contain some information about
  -- the current container state.
  --
  -- Returns 'Nothing' if the delta has no effect on the container described in
  -- the `DelteContext`. Please note that even a no-op or invalid delta will
  -- change a 'Loading' observable to 'Live'.
  validateDelta :: DeltaContext c -> Delta c v -> Maybe (ValidatedDelta c v)
  default validateDelta ::
    (ValidatedDelta c v ~ Delta c v) =>
    DeltaContext c ->
    Delta c v ->
    Maybe (ValidatedDelta c v)
  validateDelta _ = Just

  mergeDelta :: ValidatedDelta c v -> Delta c v -> ValidatedDelta c v

  -- | Get a description of a container state from a validated delta. The
  -- derived `DeltaContext` represents the state of the container after applying
  -- the delta.
  validatedDeltaToContext :: ValidatedDelta c v -> DeltaContext c
  default validatedDeltaToContext :: DeltaContext c ~ () => ValidatedDelta c v -> DeltaContext c
  validatedDeltaToContext _ = ()

  validatedDeltaToDelta :: ValidatedDelta c v -> Delta c v
  default validatedDeltaToDelta :: ValidatedDelta c v ~ Delta c v => ValidatedDelta c v -> Delta c v
  validatedDeltaToDelta = id

  toDeltaContext :: c v -> DeltaContext c
  default toDeltaContext :: DeltaContext c ~ () => c v -> DeltaContext c
  toDeltaContext _ = ()

updateDeltaContext ::
  forall c v.
  ObservableContainer c v =>
  DeltaContext c ->
  Delta c v ->
  DeltaContext c
updateDeltaContext ctx delta =
  case validateDelta @c ctx delta of
    Nothing -> ctx
    Just validated -> validatedDeltaToContext @c validated

instance ObservableContainer Identity v where
  type ContainerConstraint _canLoad _exceptions Identity v _a = ()
  type Delta Identity = Void1
  applyDelta = absurd1
  mergeDelta _ new = new
  toDeltaContext _ = ()

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

observableUpdateToChange :: ObserverContext canLoad c -> Maybe (ObservableUpdate c v) -> Maybe (ObservableChange canLoad c v)
observableUpdateToChange ObserverContextLoadingCleared Nothing = Nothing
observableUpdateToChange (ObserverContextLoadingCached _) Nothing = Just ObservableChangeLiveUnchanged
observableUpdateToChange (ObserverContextLive _) Nothing = Nothing
observableUpdateToChange ObserverContextLoadingCleared (Just (ObservableUpdateReplace new)) = Just (ObservableChangeLiveReplace new)
observableUpdateToChange ObserverContextLoadingCleared (Just (ObservableUpdateDelta _delta)) = Nothing
observableUpdateToChange (ObserverContextLoadingCached _) (Just (ObservableUpdateReplace new)) = Just (ObservableChangeLiveReplace new)
observableUpdateToChange (ObserverContextLoadingCached _) (Just (ObservableUpdateDelta delta)) = Just (ObservableChangeLiveDelta delta)
observableUpdateToChange (ObserverContextLive _) (Just (ObservableUpdateReplace new)) = Just (ObservableChangeLiveReplace new)
observableUpdateToChange (ObserverContextLive _) (Just (ObservableUpdateDelta delta)) = Just (ObservableChangeLiveDelta delta)


type ValidatedUpdate :: (Type -> Type) -> Type -> Type
data ValidatedUpdate c v where
  ValidatedUpdateReplace :: c v -> ValidatedUpdate c v
  ValidatedUpdateDelta :: ValidatedDelta c v -> ValidatedUpdate c v

deriving instance (Show (c v), Show (ValidatedDelta c v), Show (DeltaContext c)) => Show (ValidatedUpdate c v)
deriving instance (Eq (c v), Eq (ValidatedDelta c v), Eq (DeltaContext c)) => Eq (ValidatedUpdate c v)


unvalidatedUpdate :: ObservableContainer c v => Either (DeltaContext c) (ValidatedUpdate c v) -> Maybe (ObservableUpdate c v)
unvalidatedUpdate (Right update) = Just update.unvalidated
unvalidatedUpdate (Left _) = Nothing

instance ObservableContainer c v => HasField "unvalidated" (ValidatedUpdate c v) (ObservableUpdate c v) where
  getField (ValidatedUpdateReplace new) = ObservableUpdateReplace new
  getField (ValidatedUpdateDelta delta) = ObservableUpdateDelta (validatedDeltaToDelta @c delta)

instance (Functor c, Functor (ValidatedDelta c)) => Functor (ValidatedUpdate c) where
  fmap fn (ValidatedUpdateReplace new) = ValidatedUpdateReplace (fn <$> new)
  fmap fn (ValidatedUpdateDelta delta) = ValidatedUpdateDelta (fn <$> delta)

instance (Foldable c, Traversable (ValidatedDelta c)) => Foldable (ValidatedUpdate c) where
  foldMap f (ValidatedUpdateReplace x) = foldMap f x
  foldMap f (ValidatedUpdateDelta delta) = foldMap f delta

instance (Traversable c, Traversable (ValidatedDelta c)) => Traversable (ValidatedUpdate c) where
  traverse f (ValidatedUpdateReplace x) = ValidatedUpdateReplace <$> traverse f x
  traverse f (ValidatedUpdateDelta delta) = ValidatedUpdateDelta <$> traverse f delta

-- | Validate an update, based on a previous container state context.
validateUpdate ::
  forall c v. ObservableContainer c v =>
  Maybe (ObservableUpdate c v) -> DeltaContext c -> Either (DeltaContext c) (ValidatedUpdate c v)
validateUpdate Nothing oldCtx = Left oldCtx
validateUpdate (Just (ObservableUpdateReplace new)) _oldCtx =
  Right (ValidatedUpdateReplace new)
validateUpdate (Just (ObservableUpdateDelta delta)) oldCtx =
  case validateDelta @c oldCtx delta of
    Nothing -> Left oldCtx
    Just validated -> Right (ValidatedUpdateDelta validated)

validatedUpdateToContext ::
  forall c v.
  ObservableContainer c v =>
  Either (DeltaContext c) (ValidatedUpdate c v) -> DeltaContext c
validatedUpdateToContext (Right (ValidatedUpdateReplace content)) = toDeltaContext @c content
validatedUpdateToContext (Right (ValidatedUpdateDelta delta)) = validatedDeltaToContext @c delta
validatedUpdateToContext (Left ctx) = ctx

mergeValidatedUpdate ::
  forall c v.
  ObservableContainer c v =>
  Either (DeltaContext c) (ValidatedUpdate c v) ->
  Maybe (ObservableUpdate c v) ->
  Either (DeltaContext c) (ValidatedUpdate c v)
mergeValidatedUpdate _ (Just (ObservableUpdateReplace new)) = Right (ValidatedUpdateReplace new)
mergeValidatedUpdate old Nothing = old
mergeValidatedUpdate (Left ctx) (Just (ObservableUpdateDelta delta)) =
  case validateDelta @c ctx delta of
    Nothing -> Left ctx
    Just validated -> Right (ValidatedUpdateDelta validated)
mergeValidatedUpdate (Right oldUpdate@(ValidatedUpdateReplace old)) (Just (ObservableUpdateDelta delta)) = do
  case applyDelta @c delta old of
    Nothing -> Right oldUpdate
    Just new -> Right (ValidatedUpdateReplace new)
mergeValidatedUpdate (Right (ValidatedUpdateDelta oldDelta)) (Just (ObservableUpdateDelta delta)) =
  Right (ValidatedUpdateDelta (mergeDelta @c oldDelta delta))



type EvaluatedUpdate :: (Type -> Type) -> Type -> Type
data EvaluatedUpdate c v where
  EvaluatedUpdateReplace :: c v -> EvaluatedUpdate c v
  EvaluatedUpdateDelta :: EvaluatedDelta c v -> EvaluatedUpdate c v

pattern EvaluatedUpdateOk :: EvaluatedUpdate c v -> EvaluatedUpdate (ObservableResult exceptions c) v
pattern EvaluatedUpdateOk update <- (evaluatedUpdateToEither -> Right update) where
  EvaluatedUpdateOk (EvaluatedUpdateReplace x) = EvaluatedUpdateReplace (ObservableResultOk x)
  EvaluatedUpdateOk (EvaluatedUpdateDelta (delta, content)) = EvaluatedUpdateDelta (delta, ObservableResultOk content)

pattern EvaluatedUpdateThrow :: Ex exceptions -> EvaluatedUpdate (ObservableResult exceptions c) v
pattern EvaluatedUpdateThrow ex <- (evaluatedUpdateToEither -> Left ex) where
  EvaluatedUpdateThrow ex = EvaluatedUpdateReplace (ObservableResultEx ex)

evaluatedUpdateToEither ::
  EvaluatedUpdate (ObservableResult exceptions c) v ->
  Either (Ex exceptions) (EvaluatedUpdate c v)
evaluatedUpdateToEither (EvaluatedUpdateReplace (ObservableResultOk x)) = Right (EvaluatedUpdateReplace x)
evaluatedUpdateToEither (EvaluatedUpdateReplace (ObservableResultEx ex)) = Left ex
evaluatedUpdateToEither (EvaluatedUpdateDelta (delta, ObservableResultOk content)) = Right (EvaluatedUpdateDelta (delta, content))
evaluatedUpdateToEither (EvaluatedUpdateDelta (_delta, ObservableResultEx ex)) = Left ex

{-# COMPLETE EvaluatedUpdateOk, EvaluatedUpdateThrow #-}

instance HasField "content" (EvaluatedUpdate c v) (c v) where
  getField (EvaluatedUpdateReplace content) = content
  getField (EvaluatedUpdateDelta delta) = contentFromEvaluatedDelta delta

instance HasField "notEvaluated" (EvaluatedUpdate c v) (ObservableUpdate c v) where
  getField (EvaluatedUpdateReplace content) = ObservableUpdateReplace content
  getField (EvaluatedUpdateDelta (delta, _)) = ObservableUpdateDelta delta


type ObservableChange :: LoadKind -> (Type -> Type) -> Type -> Type
data ObservableChange canLoad c v where
  ObservableChangeLoadingClear :: ObservableChange Load c v
  ObservableChangeLoadingUnchanged :: ObservableChange Load c v
  ObservableChangeLiveUnchanged :: ObservableChange Load c v
  ObservableChangeLiveReplace :: c v -> ObservableChange canLoad c v
  ObservableChangeLiveDelta :: Delta c v -> ObservableChange canLoad c v

observableChangeLiveIsUpdate :: ObservableChange canLoad c v -> Maybe (ObservableUpdate c v)
observableChangeLiveIsUpdate (ObservableChangeLiveReplace content) = Just (ObservableUpdateReplace content)
observableChangeLiveIsUpdate (ObservableChangeLiveDelta delta) = Just (ObservableUpdateDelta delta)
observableChangeLiveIsUpdate _ = Nothing

deriving instance (Show (c v), Show (Delta c v)) => Show (ObservableChange canLoad c v)
deriving instance (Eq (c v), Eq (Delta c v)) => Eq (ObservableChange canLoad c v)

instance (Functor c, Functor (Delta c)) => Functor (ObservableChange canLoad c) where
  fmap _fn ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  fmap _fn ObservableChangeLoadingClear = ObservableChangeLoadingClear
  fmap _fn ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  fmap fn (ObservableChangeLiveReplace new) = ObservableChangeLiveReplace (fn <$> new)
  fmap fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fn <$> delta)

instance (Foldable c, Traversable (Delta c)) => Foldable (ObservableChange canLoad c) where
  foldMap f (ObservableChangeLiveReplace new) = foldMap f new
  foldMap f (ObservableChangeLiveDelta delta) = foldMap f delta
  foldMap _ _ = mempty

instance (Traversable c, Traversable (Delta c)) => Traversable (ObservableChange canLoad c) where
  traverse _fn ObservableChangeLoadingUnchanged = pure ObservableChangeLoadingUnchanged
  traverse _fn ObservableChangeLoadingClear = pure ObservableChangeLoadingClear
  traverse _fn ObservableChangeLiveUnchanged = pure ObservableChangeLiveUnchanged
  traverse f (ObservableChangeLiveReplace new) = ObservableChangeLiveReplace <$> traverse f new
  traverse f (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta <$> traverse f delta

mapObservableChange :: (ca va -> c v) -> (Delta ca va -> Delta c v) -> ObservableChange canLoad ca va -> ObservableChange canLoad c v
mapObservableChange _ _ ObservableChangeLoadingClear = ObservableChangeLoadingClear
mapObservableChange _ _ ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
mapObservableChange _ _ ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
mapObservableChange fc _fd (ObservableChangeLiveReplace content) = ObservableChangeLiveReplace (fc content)
mapObservableChange _fc fd (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta (fd delta)

mapObservableChangeResult :: (ca va -> c v) -> (Delta ca va -> Delta c v) -> ObservableChange canLoad (ObservableResult exceptions ca) va -> ObservableChange canLoad (ObservableResult exceptions c) v
mapObservableChangeResult fc = mapObservableChange (mapObservableResult fc)

mapObservableChangeResultEx :: (Ex ea -> Ex eb) -> ObservableChange canLoad (ObservableResult ea c) v -> ObservableChange canLoad (ObservableResult eb c) v
mapObservableChangeResultEx _ ObservableChangeLoadingClear = ObservableChangeLoadingClear
mapObservableChangeResultEx _ ObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
mapObservableChangeResultEx _ ObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
mapObservableChangeResultEx _fn (ObservableChangeLiveReplace (ObservableResultOk content)) = ObservableChangeLiveReplace (ObservableResultOk content)
mapObservableChangeResultEx fn (ObservableChangeLiveReplace (ObservableResultEx ex)) = ObservableChangeLiveReplace (ObservableResultEx (fn ex))
mapObservableChangeResultEx _fn (ObservableChangeLiveDelta delta) = ObservableChangeLiveDelta delta


type ValidatedChange :: LoadKind -> (Type -> Type) -> Type -> Type
data ValidatedChange canLoad c v where
  ValidatedChangeLoadingClear :: ValidatedChange Load c v
  ValidatedChangeLoadingUnchanged :: DeltaContext c -> ValidatedChange Load c v
  ValidatedChangeLiveUnchanged :: DeltaContext c -> ValidatedChange Load c v
  ValidatedChangeLiveReplace :: c v -> ValidatedChange canLoad c v
  ValidatedChangeLiveDelta :: ValidatedDelta c v -> ValidatedChange canLoad c v

deriving instance (Show (c v), Show (DeltaContext c), Show (ValidatedDelta c v)) => Show (ValidatedChange canLoad c v)
deriving instance (Eq (c v), Eq (DeltaContext c), Eq (ValidatedDelta c v)) => Eq (ValidatedChange canLoad c v)

instance ObservableContainer c v => HasField "context" (ValidatedChange canLoad c v) (ObserverContext canLoad c) where
  getField ValidatedChangeLoadingClear = ObserverContextLoadingCleared
  getField (ValidatedChangeLoadingUnchanged ctx) = ObserverContextLoadingCached ctx
  getField (ValidatedChangeLiveUnchanged ctx) = ObserverContextLive ctx
  getField (ValidatedChangeLiveReplace new) = ObserverContextLive (toDeltaContext @c new)
  getField (ValidatedChangeLiveDelta delta) = ObserverContextLive (validatedDeltaToContext @c delta)

instance ObservableContainer c v => HasField "unvalidated" (ValidatedChange canLoad c v) (ObservableChange canLoad c v) where
  getField ValidatedChangeLoadingClear = ObservableChangeLoadingClear
  getField (ValidatedChangeLoadingUnchanged _ctx) = ObservableChangeLoadingUnchanged
  getField (ValidatedChangeLiveUnchanged _ctx) = ObservableChangeLiveUnchanged
  getField (ValidatedChangeLiveReplace new) = ObservableChangeLiveReplace new
  getField (ValidatedChangeLiveDelta delta) = ObservableChangeLiveDelta (validatedDeltaToDelta @c delta)

instance (Functor c, Functor (ValidatedDelta c)) => Functor (ValidatedChange canLoad c) where
  fmap _fn ValidatedChangeLoadingClear = ValidatedChangeLoadingClear
  fmap _fn (ValidatedChangeLoadingUnchanged ctx) = ValidatedChangeLoadingUnchanged ctx
  fmap _fn (ValidatedChangeLiveUnchanged ctx) = ValidatedChangeLiveUnchanged ctx
  fmap fn (ValidatedChangeLiveReplace new) = ValidatedChangeLiveReplace (fn <$> new)
  fmap fn (ValidatedChangeLiveDelta delta) = ValidatedChangeLiveDelta (fn <$> delta)

instance (Foldable c, Traversable (ValidatedDelta c)) => Foldable (ValidatedChange canLoad c) where
  foldMap f (ValidatedChangeLiveReplace new) = foldMap f new
  foldMap f (ValidatedChangeLiveDelta delta) = foldMap f delta
  foldMap _ _ = mempty

instance (Traversable c, Traversable (ValidatedDelta c)) => Traversable (ValidatedChange canLoad c) where
  traverse _fn ValidatedChangeLoadingClear = pure ValidatedChangeLoadingClear
  traverse _fn (ValidatedChangeLoadingUnchanged ctx) = pure (ValidatedChangeLoadingUnchanged ctx)
  traverse _fn (ValidatedChangeLiveUnchanged ctx) = pure (ValidatedChangeLiveUnchanged ctx)
  traverse f (ValidatedChangeLiveReplace new) = ValidatedChangeLiveReplace <$> traverse f new
  traverse f (ValidatedChangeLiveDelta delta) = ValidatedChangeLiveDelta <$> traverse f delta

validateChange ::
  forall canLoad c v.
  ObservableContainer c v =>
  ObserverContext canLoad c ->
  ObservableChange canLoad c v ->
  Maybe (ValidatedChange canLoad c v)
validateChange _ ObservableChangeLoadingClear = Just ValidatedChangeLoadingClear
validateChange _ (ObservableChangeLiveReplace new) = Just (ValidatedChangeLiveReplace new)

validateChange ObserverContextLoadingCleared ObservableChangeLoadingUnchanged = Nothing
validateChange ObserverContextLoadingCleared ObservableChangeLiveUnchanged = Nothing
validateChange ObserverContextLoadingCleared (ObservableChangeLiveDelta _delta) = Nothing

validateChange (ObserverContextLoadingCached _ctx) ObservableChangeLoadingUnchanged = Nothing
validateChange (ObserverContextLoadingCached ctx) ObservableChangeLiveUnchanged =
  Just (ValidatedChangeLiveUnchanged ctx)
validateChange (ObserverContextLoadingCached ctx) (ObservableChangeLiveDelta delta) = Just
  case validateDelta @c ctx delta of
    Nothing -> ValidatedChangeLiveUnchanged ctx
    Just validated -> ValidatedChangeLiveDelta validated

validateChange (ObserverContextLive ctx) ObservableChangeLoadingUnchanged = Just (ValidatedChangeLoadingUnchanged ctx)
validateChange (ObserverContextLive ctx) ObservableChangeLiveUnchanged = Nothing
validateChange (ObserverContextLive ctx) (ObservableChangeLiveDelta delta) =
  case validateDelta @c ctx delta of
    Nothing -> Nothing -- Invalid delta, already live, so no effect
    Just validated -> Just (ValidatedChangeLiveDelta validated)


type EvaluatedObservableChange :: LoadKind -> (Type -> Type) -> Type -> Type
data EvaluatedObservableChange canLoad c v where
  EvaluatedObservableChangeLoadingUnchanged :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLoadingClear :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLiveUnchanged :: EvaluatedObservableChange Load c v
  EvaluatedObservableChangeLiveReplace :: c v -> EvaluatedObservableChange canLoad c v
  EvaluatedObservableChangeLiveDelta :: EvaluatedDelta c v -> EvaluatedObservableChange canLoad c v

instance HasField "notEvaluated" (EvaluatedObservableChange canLoad c v) (ObservableChange canLoad c v) where
  getField EvaluatedObservableChangeLoadingClear = ObservableChangeLoadingClear
  getField EvaluatedObservableChangeLoadingUnchanged = ObservableChangeLoadingUnchanged
  getField EvaluatedObservableChangeLiveUnchanged = ObservableChangeLiveUnchanged
  getField (EvaluatedObservableChangeLiveReplace new) = ObservableChangeLiveReplace new
  getField (EvaluatedObservableChangeLiveDelta (delta, _)) = ObservableChangeLiveDelta delta

type ObservableState :: LoadKind -> (Type -> Type) -> Type -> Type
data ObservableState canLoad c v where
  ObservableStateLoading :: ObservableState Load c v
  ObservableStateLive :: c v -> ObservableState canLoad c v

{-# COMPLETE ObservableStateLiveOk, ObservableStateLiveEx, ObservableStateLoading #-}

pattern ObservableStateLiveOk :: forall canLoad exceptions c v. c v -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveOk content = ObservableStateLive (ObservableResultOk content)

pattern ObservableStateLiveEx :: forall canLoad exceptions c v. Ex exceptions -> ObservableState canLoad (ObservableResult exceptions c) v
pattern ObservableStateLiveEx ex = ObservableStateLive (ObservableResultEx ex)

deriving instance Show (c v) => Show (ObservableState canLoad c v)
deriving instance Eq (c v) => Eq (ObservableState canLoad c v)

instance Semigroup (c v) => Semigroup (ObservableState canLoad c v) where
  ObservableStateLive x <> ObservableStateLive y = ObservableStateLive (x <> y)
  ObservableStateLoading <> _ = ObservableStateLoading
  _ <> ObservableStateLoading = ObservableStateLoading

instance IsObservableCore canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v) where
  readObservable# = pure
  attachObserver# x _callback = pure (mempty, x)
  isSharedObservable# _ = True
  count# x = constObservable (mapObservableStateResult (Identity . containerCount#) x)
  isEmpty# x = constObservable (mapObservableStateResult (Identity . containerIsEmpty#) x)

instance (ContainerConstraint canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v)) => ToObservableT canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v) where
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

deriving instance Show (c v) => Show (ObserverState canLoad c v)
deriving instance Eq (c v) => Eq (ObserverState canLoad c v)
deriving instance Ord (c v) => Ord (ObserverState canLoad c v)

instance Foldable c => Foldable (ObserverState canLoad c) where
  foldMap fn ObserverStateLoadingCleared = mempty
  foldMap fn (ObserverStateLoadingCached x) = foldMap fn x
  foldMap fn (ObserverStateLive x) = foldMap fn x
  foldr _ initial ObserverStateLoadingCleared = initial
  foldr fn i (ObserverStateLoadingCached x) = foldr fn i x
  foldr fn i (ObserverStateLive x) = foldr fn i x

instance HasField "loading" (ObserverState canLoad c v) (Loading canLoad) where
  getField ObserverStateLoadingCleared = Loading
  getField (ObserverStateLoadingCached _) = Loading
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
  getField (ObserverStateLoadingCached cache) = ObserverContextLoadingCached (toDeltaContext cache)
  getField (ObserverStateLive state) = ObserverContextLive (toDeltaContext state)

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
updateObserverContext _ (ObservableChangeLiveReplace new) = ObserverContextLive (toDeltaContext new)
updateObserverContext ObserverContextLoadingCleared (ObservableChangeLiveDelta _delta) =
  ObserverContextLoadingCleared
updateObserverContext (ObserverContextLoadingCached deltaContext) (ObservableChangeLiveDelta delta) =
  ObserverContextLive (updateDeltaContext @c deltaContext delta)
updateObserverContext (ObserverContextLive deltaContext) (ObservableChangeLiveDelta delta) =
  ObserverContextLive (updateDeltaContext @c deltaContext delta)


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
  Just (EvaluatedObservableChangeLiveReplace content, ObserverStateLive content)

applyObservableChange (ObservableChangeLiveDelta _delta) ObserverStateLoadingCleared = Nothing
applyObservableChange (ObservableChangeLiveDelta delta) (ObserverStateCached loading old) =
  case applyDelta delta old of
    Nothing -> case loading of
      -- Delta has no effect except to change to Live
      Loading -> Just (EvaluatedObservableChangeLiveUnchanged, ObserverStateLive old)
      -- Already live
      Live -> Nothing
    Just new -> Just (EvaluatedObservableChangeLiveDelta (delta, new), ObserverStateLive new)

applyEvaluatedObservableChange ::
  EvaluatedObservableChange canLoad c v ->
  ObserverState canLoad c v ->
  Maybe (ObserverState canLoad c v)
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingClear _ = Just ObserverStateLoadingCleared
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLoadingCached _) = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLoadingUnchanged (ObserverStateLive state) = Just (ObserverStateLoadingCached state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLoadingCached state) = Just (ObserverStateLive state)
applyEvaluatedObservableChange EvaluatedObservableChangeLiveUnchanged (ObserverStateLive _) = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveDelta _) ObserverStateLoadingCleared = Nothing
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveDelta (_, content)) _ = Just (ObserverStateLive content)
applyEvaluatedObservableChange (EvaluatedObservableChangeLiveReplace content) _ = Just (ObserverStateLive content)


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

toReplacingChange :: ObservableState canLoad c v -> ObservableChange canLoad c v
toReplacingChange ObservableStateLoading = ObservableChangeLoadingClear
toReplacingChange (ObservableStateLive x) = ObservableChangeLiveReplace x


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
  PendingChangeAlter :: Loading canLoad -> Either (DeltaContext c) (ValidatedUpdate c v) -> PendingChange canLoad c v

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
  PendingChangeAlter Live (Right (ValidatedUpdateReplace content))
updatePendingChange (ObservableChangeLiveDelta _delta) PendingChangeLoadingClear =
  PendingChangeLoadingClear
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading (Right (ValidatedUpdateReplace prevReplace))) =
  case applyDelta @c delta prevReplace of
    Nothing -> PendingChangeAlter Live (Right (ValidatedUpdateReplace prevReplace))
    Just new -> PendingChangeAlter Live (Right (ValidatedUpdateReplace new))
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading (Right (ValidatedUpdateDelta prevDelta))) =
  PendingChangeAlter Live (Right (ValidatedUpdateDelta (mergeDelta @c prevDelta delta)))
updatePendingChange (ObservableChangeLiveDelta delta) (PendingChangeAlter _loading (Left ctx)) =
  case validateDelta @c ctx delta of
    Nothing ->
      -- Invalid delta, cannot apply but change from loading to live
      PendingChangeAlter Live (Left ctx)
    Just validatedDelta -> PendingChangeAlter Live (Right (ValidatedUpdateDelta validatedDelta))

initialPendingChange :: ObservableContainer c v => ObservableState canLoad c v -> PendingChange canLoad c v
initialPendingChange ObservableStateLoading = PendingChangeLoadingClear
initialPendingChange (ObservableStateLive initial) = PendingChangeAlter Live (Left (toDeltaContext initial))

unchangedPendingChange :: ObservableContainer c v => c v -> PendingChange canLoad c v
unchangedPendingChange initial = PendingChangeAlter Live (Left (toDeltaContext initial))

initialLastChange :: ObservableState canLoad c v -> LastChange canLoad
initialLastChange ObservableStateLoading = LastChangeLoadingCleared
initialLastChange (ObservableStateLive _) = LastChangeLive

replacingPendingChange :: ObservableState canLoad c v -> PendingChange canLoad c v
replacingPendingChange ObservableStateLoading = PendingChangeLoadingClear
replacingPendingChange (ObservableStateLive initial) = PendingChangeAlter Live (Right (ValidatedUpdateReplace initial))

initialPendingAndLastChange :: ObservableContainer c v => ObservableState canLoad c v -> (PendingChange canLoad c v, LastChange canLoad)
initialPendingAndLastChange ObservableStateLoading =
  (PendingChangeLoadingClear, LastChangeLoadingCleared)
initialPendingAndLastChange (ObservableStateLive initial) =
  let ctx = toDeltaContext initial
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
    changeFromPending' Live (PendingChangeAlter Live (Right (ValidatedUpdateDelta _delta))) LastChangeLoadingCleared = Nothing
    changeFromPending' Live x@(PendingChangeAlter Live (Left _)) LastChangeLoading = Just (ObservableChangeLiveUnchanged, x)
    changeFromPending' Live (PendingChangeAlter Live (Left _)) LastChangeLive = Nothing
    changeFromPending' Live x@(PendingChangeAlter Live (Right (ValidatedUpdateReplace new))) _lc =
      Just (ObservableChangeLiveReplace new, PendingChangeAlter Live (Left (toDeltaContext new)))
    changeFromPending' Live x@(PendingChangeAlter Live (Right (ValidatedUpdateDelta delta))) _lc =
      Just (ObservableChangeLiveDelta (validatedDeltaToDelta @c delta), PendingChangeAlter Live (Left (validatedDeltaToContext @c delta)))

    updateLastChange :: ObservableChange canLoad c v -> LastChange canLoad -> LastChange canLoad
    updateLastChange ObservableChangeLoadingClear _ = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLoadingUnchanged _ = LastChangeLoading
    updateLastChange ObservableChangeLiveUnchanged LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange ObservableChangeLiveUnchanged _ = LastChangeLive
    updateLastChange (ObservableChangeLiveReplace _) _ = LastChangeLive
    -- Applying a Delta to a Cleared state is a no-op.
    updateLastChange (ObservableChangeLiveDelta _) LastChangeLoadingCleared = LastChangeLoadingCleared
    updateLastChange (ObservableChangeLiveDelta _) _ = LastChangeLive


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
        EvaluatedObservableChangeLiveReplace new -> EvaluatedObservableChangeLiveReplace (mapObservableResult Identity new)
        EvaluatedObservableChangeLiveDelta (_, new) -> EvaluatedObservableChangeLiveReplace (mapObservableResult Identity new)

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
  -> STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
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
  -> STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
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

mergeCallback ::
  forall canLoad c v ca va cb vb.
  ObservableContainer c v =>
  TVar (ObserverState canLoad ca va) ->
  TVar (ObserverState canLoad cb vb) ->
  TVar (PendingChange canLoad c v, LastChange canLoad) ->
  (ca va -> cb vb -> c v) ->
  (EvaluatedUpdate ca va -> Maybe (ca va) -> MaybeL canLoad (cb vb) -> Maybe (MergeChange canLoad c v)) ->
  (canLoad :~: Load -> ca va -> cb vb -> Maybe (MergeChange canLoad c v)) ->
  (ObservableChange canLoad c v -> STMc NoRetry '[] ()) ->
  EvaluatedObservableChange canLoad ca va -> STMc NoRetry '[] ()
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
          EvaluatedObservableChangeLiveReplace new ->
            mapM_ (applyMergeChange otherState.loading) (fn (EvaluatedUpdateReplace new) oldState.maybe otherState.maybeL)
          EvaluatedObservableChangeLiveDelta delta ->
            mapM_ (applyMergeChange otherState.loading) (fn (EvaluatedUpdateDelta delta) oldState.maybe otherState.maybeL)
  where
    reinitialize :: ca va -> cb vb -> STMc NoRetry '[] ()
    reinitialize x y = applyChange Live (ObservableChangeLiveReplace (fullMergeFn x y))

    clearOur :: canLoad ~ Load => ca va -> MaybeL Load (cb vb) -> STMc NoRetry '[] ()
    -- Both sides are cleared now
    clearOur _prev NothingL = applyChange Loading ObservableChangeLoadingClear
    clearOur prev (JustL other) = mapM_ (applyMergeChange Loading) (clearFn Refl prev other)

    applyMergeChange :: Loading canLoad -> MergeChange canLoad c v -> STMc NoRetry '[] ()
    applyMergeChange _loading MergeChangeClear = applyChange Loading ObservableChangeLoadingClear
    applyMergeChange loading (MergeChangeUpdate (ObservableUpdateReplace new)) = applyChange loading (ObservableChangeLiveReplace new)
    applyMergeChange loading (MergeChangeUpdate (ObservableUpdateDelta delta)) = applyChange loading (ObservableChangeLiveDelta delta)

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
  -> STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
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


attachContextMergeObserver ::
  forall canLoad exceptions c v ca va cb vb a b.
  (
    IsObservableCore canLoad exceptions ca va a,
    IsObservableCore canLoad exceptions cb vb b,
    ObservableContainer ca va,
    ObservableContainer cb vb,
    ObservableContainer c v
  ) =>
  -- Function to merge the container during (re)initialisation.
  (ca va -> cb vb -> c v) ->
  -- Function to merge updates. Provides a validated update and the previous context for each side.
  ((Maybe (ValidatedUpdate ca va), DeltaContext ca) -> (Maybe (ValidatedUpdate cb vb), DeltaContext cb ) -> Maybe (ObservableUpdate c v)) ->
  -- LHS observable input.
  a ->
  -- RHS observable input.
  b ->
  -- The remainder of the signature matches `attachObserver`, so it can be used
  -- as an implementation for it.
  (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) ->
  STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachContextMergeObserver containerMergeFn mergeFn fx fy callback = undefined



data BindState canLoad c v where
  -- LHS cleared
  BindStateDetached :: BindState Load c v
  -- RHS attached
  BindStateAttached
    :: Loading canLoad -- ^ is LHS loading
    -> TDisposer -- ^ RHS disposer
    -> (PendingChange canLoad c v, LastChange canLoad) -- ^ RHS pending change
    -> BindState canLoad c v


type BindObservable :: LoadKind -> [Type] -> [Type] -> Type -> Type -> Type
data BindObservable canLoad exceptions exceptionsA va b
  = BindObservable (Observable canLoad exceptionsA va) (ObservableResult exceptionsA Identity va -> b)

instance (IsObservableCore canLoad exceptions c v b, ObservableContainer c v) => IsObservableCore canLoad exceptions c v (BindObservable canLoad exceptions exceptionsA va b) where
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

      rhsDisposer <- newTDisposer do
        readTVar var >>= \case
          (BindStateAttached _ disposer _) -> disposeTDisposer disposer
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
            disposeTDisposer disposer
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
        -> ObservableResult exceptionsA Identity va
        -> STMc NoRetry '[] ()
      lhsReplace var x = do
        readTVar var >>= \case
          BindStateAttached _loading disposer (_pending, last) -> do
            disposeTDisposer disposer
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
        -> TDisposer
        -> PendingChange canLoad (ObservableResult exceptions c) v -- RHS pending change
        -> LastChange canLoad
        -> STMc NoRetry '[] ()
      writeAndSendPending var loading disposer pending last =
        case changeFromPending loading pending last of
          Nothing -> writeTVar var (BindStateAttached loading disposer (pending, last))
          Just (change, newPending, newLast) -> do
            writeTVar var (BindStateAttached loading disposer (newPending, newLast))
            callback change

bindObservableT ::
  forall canLoad exceptions c v va.
  (
    ObservableContainer c v,
    ContainerConstraint canLoad exceptions c v (BindObservable canLoad exceptions exceptions va (ObservableT canLoad exceptions c v)),
    ContainerConstraint canLoad exceptions c v (ObservableState canLoad (ObservableResult exceptions c) v)
  )
  => Observable canLoad exceptions va -> (va -> ObservableT canLoad exceptions c v) -> ObservableT canLoad exceptions c v
bindObservableT fx fn = ObservableT (BindObservable @canLoad @exceptions fx rhsHandler)
    where
      rhsHandler (ObservableResultOk (Identity x)) = fn x
      rhsHandler (ObservableResultEx ex) = ObservableT (ObservableStateLiveEx ex)



instance IsObservableCore Load exceptions Identity v (FutureEx exceptions v) where
  readObservable# future = do
    peekFuture future <&> \case
      Nothing -> ObservableStateLoading
      Just (Left ex) -> ObservableStateLive (ObservableResultEx ex)
      Just (Right value) -> ObservableStateLive (ObservableResultOk (Identity value))

  attachObserver# future callback = do
    initial <- readOrAttachToFuture# (toFuture future) \result ->
      callback $ ObservableChangeLiveReplace $ case result of
        Left ex -> ObservableResultEx ex
        Right value -> ObservableResultOk (Identity value)
    pure case initial of
      Left disposer -> (disposer, ObservableStateLoading)
      Right (Right value) -> (mempty, ObservableStateLive (ObservableResultOk (Identity value)))
      Right (Left ex) -> (mempty, ObservableStateLive (ObservableResultEx ex))

instance ToObservableT Load exceptions Identity v (FutureEx exceptions v) where
  toObservableT = ObservableT



attachDeltaRemappingObserver ::
  forall canLoad exceptions ca va c v.
  ObservableContainer ca va =>
  ObservableT canLoad exceptions ca va ->
  (ca va -> c v) -> -- ^ Content remap function. The first argument ist the current container state.
  (ca va -> Delta ca va -> Maybe (ObservableUpdate c v)) -> -- ^ Delta remap function. The first argument is the previous container state.
  (ObservableChange canLoad (ObservableResult exceptions c) v -> STMc NoRetry '[] ()) ->
  STMc NoRetry '[] (TDisposer, ObservableState canLoad (ObservableResult exceptions c) v)
attachDeltaRemappingObserver x resetFn deltaFn callback =
  mfixTVar \var -> do
    (disposer, initial) <- attachEvaluatedObserver# x \case
      EvaluatedObservableChangeLoadingClear -> do
        writeTVar var ObserverStateLoadingCleared
        callback ObservableChangeLoadingClear
      EvaluatedObservableChangeLoadingUnchanged -> callback ObservableChangeLoadingUnchanged
      EvaluatedObservableChangeLiveUnchanged -> callback ObservableChangeLiveUnchanged
      EvaluatedObservableChangeLiveReplace (ObservableResultOk new) -> do
        writeTVar var (ObserverStateLive (ObservableResultOk new))
        callback (ObservableChangeLiveReplace (ObservableResultOk (resetFn new)))
      EvaluatedObservableChangeLiveReplace result@(ObservableResultEx ex) -> do
          writeTVar var (ObserverStateLive result)
          callback (ObservableChangeLiveReplace (ObservableResultEx ex))
      EvaluatedObservableChangeLiveDelta (delta, result) ->
        readTVar var >>= \case
          ObserverStateLoadingCleared -> pure () -- no effect
          ObserverStateLoadingCached (ObservableResultOk cached) -> do
            writeTVar var (ObserverStateLive result)
            handleDelta var cached delta
          ObserverStateLoadingCached (ObservableResultEx ex) -> do
            writeTVar var (ObserverStateLive (ObservableResultEx ex))
            callback ObservableChangeLiveUnchanged
          ObserverStateLive (ObservableResultOk content) -> do
            writeTVar var (ObserverStateLive result)
            handleDelta var content delta
          ObserverStateLive (ObservableResultEx _ex) -> pure () -- no effect

    pure ((disposer, mapObservableStateResult resetFn initial), createObserverState initial)
  where
    handleDelta :: TVar (ObserverState canLoad (ObservableResult exceptions ca) va) -> ca va -> Delta ca va -> STMc NoRetry '[] ()
    handleDelta var content delta = do
      let update = deltaFn content delta
      case update of
        Nothing -> pure ()
        Just (ObservableUpdateReplace newContent) ->
          callback (ObservableChangeLiveReplace (ObservableResultOk newContent))
        Just (ObservableUpdateDelta newDelta) ->
          callback (ObservableChangeLiveDelta newDelta)



newtype SkipUpdateIfEqual canLoad exceptions c v = SkipUpdateIfEqual (ObservableT canLoad exceptions c v)

instance Eq (c v) => IsObservableCore canLoad exceptions c v (SkipUpdateIfEqual canLoad exceptions c v) where
  readObservable# (SkipUpdateIfEqual fx) = readObservable# fx

  attachEvaluatedObserver# (SkipUpdateIfEqual fx) callback = do
    mfixTVar \var -> do
      (disposer, initial) <- attachEvaluatedObserver# fx \change -> do
        oldState <- readTVar var
        forM_ (applyEvaluatedObservableChange change oldState) \newState ->
          case (oldState, newState) of
            (ObserverStateLive (ObservableResultOk oldContent), ObserverStateLive (ObservableResultOk newContent)) -> do
              unless (oldContent == newContent) do
                writeTVar var newState
                callback change
            (ObserverStateLoadingCached (ObservableResultOk oldContent), ObserverStateLive (ObservableResultOk newContent)) -> do
              writeTVar var newState
              callback case change of
                EvaluatedObservableChangeLiveUnchanged -> EvaluatedObservableChangeLiveUnchanged
                _ | oldContent == newContent -> EvaluatedObservableChangeLiveUnchanged
                _ -> change
            (_, ObserverStateLive (ObservableResultEx _ex)) | otherwise -> do
              case change of
                EvaluatedObservableChangeLiveDelta _ -> pure ()
                _ -> do
                  writeTVar var newState
                  callback change
            _ -> do
              writeTVar var newState
              callback change

      pure ((disposer, initial), createObserverState initial)


-- TODO move to Observable module
skipUpdateIfEqual ::
  Eq v =>
  Observable canLoad exceptions v ->
  Observable canLoad exceptions v
skipUpdateIfEqual (Observable fx) = Observable (ObservableT (SkipUpdateIfEqual fx))



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
  toObservableT (Observable x) = x

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

instance Semigroup v => Semigroup (Observable canLoad exceptions v) where
  fx <> fy = liftA2 (<>) fx fy

instance Monoid v => Monoid (Observable canLoad exceptions v) where
  mempty = pure mempty

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

instance SomeException :< exceptions => MonadCatch (Observable canLoad exceptions) where
  catch fx fn = Observable (ObservableT (BindObservable fx rhsHandler))
    where
      rhsHandler (ObservableResultOk (Identity x)) = pure x
      rhsHandler (ObservableResultEx ex) =
        case fromException (exToException ex) of
          Nothing -> throwExObservable ex
          Just match -> fn match

instance IsObservableCore canLoad exceptions Identity v (Observable canLoad exceptions v) where
  readObservable# (Observable x) = readObservable# x
  attachObserver# (Observable x) = attachObserver# x
  attachEvaluatedObserver# (Observable x) = attachEvaluatedObserver# x
  isSharedObservable# (Observable x) = isSharedObservable# x
  mapObservable# f (Observable x) = mapObservable# f x
  count# (Observable x) = count# x
  isEmpty# (Observable x) = isEmpty# x

constObservable :: ObservableState canLoad (ObservableResult exceptions Identity) v -> Observable canLoad exceptions v
constObservable state = Observable (ObservableT state)

-- | Can be used instead of `throwEx` when the exception list cannot be
-- evaluated at compile time.
throwExObservable :: Ex exceptions -> Observable canLoad exceptions v
throwExObservable = unsafeThrowEx . exToException

catchObservable ::
  forall canLoad exceptions e v.
  Exception e =>
  Observable canLoad exceptions v ->
  (e -> Observable canLoad (exceptions :- e) v) ->
  Observable canLoad (exceptions :- e) v
catchObservable fx fn = Observable (ObservableT (BindObservable fx rhsHandler))
  where
    rhsHandler (ObservableResultOk (Identity x)) = pure x
    rhsHandler (ObservableResultEx ex) =
      case matchEx ex of
        Left unmatched -> throwExObservable unmatched
        Right match -> fn match

catchAllObservable ::
  forall canLoad exceptions v.
  Observable canLoad exceptions v ->
  (SomeException -> Observable canLoad '[] v) ->
  Observable canLoad '[] v
catchAllObservable fx fn = Observable (ObservableT (BindObservable fx rhsHandler))
  where
    rhsHandler (ObservableResultOk (Identity x)) = pure x
    rhsHandler (ObservableResultEx ex) = fn (exToException ex)

attachSimpleObserver ::
  Observable NoLoad '[] v ->
  (v -> STMc NoRetry '[] ()) ->
  STMc NoRetry '[] (TDisposer, v)
attachSimpleObserver observable callback = do
  (disposer, initial) <- attachObserver# observable \case
    ObservableChangeLiveReplace (ObservableResultTrivial (Identity new)) -> callback new
    ObservableChangeLiveDelta delta -> absurd1 delta
  case initial of
    ObservableStateLive (ObservableResultTrivial (Identity x)) -> pure (disposer, x)


observeWith ::
  forall l e a m b.
  (MonadIO m, MonadMask m) =>
  Observable l e a ->
  (STMc Retry '[] (Either (Ex e) a) -> m b) ->
  m b
observeWith obs code = bracket (liftIO aquire) (liftIO . release) (code . snd)
  where
    aquire :: IO (TDisposer, STMc Retry '[] (Either (Ex e) a))
    aquire = atomicallyC do
      seenVar <- newTVar False
      mfixTVar \var -> do
        (disposer, initial) <- attachObserver# obs \change -> do
          state <- readTVar var
          forM_ (applyObservableChange change state) \(_, newState) -> do
            writeTVar var newState
            case change of
              ObservableChangeLiveReplace _ -> writeTVar seenVar False
              _ -> pure ()
        pure ((disposer, get seenVar var), createObserverState initial)

    release :: (TDisposer, STMc Retry '[] (Either (Ex e) a)) -> IO ()
    release (disposer, _) = atomically $ disposeTDisposer disposer

    get :: TVar Bool -> TVar (ObserverState l (ObservableResult e Identity) a) -> STMc Retry '[] (Either (Ex e) a)
    get seenVar var = do
      whenM (readTVar seenVar) retry
      result <- readTVar var >>= \case
        ObserverStateLive (ObservableResultOk (Identity x)) -> pure (Right x)
        ObserverStateLive (ObservableResultEx ex) -> pure (Left ex)
        _ -> retry -- Loading
      writeTVar seenVar True
      pure result

observeBlocking ::
  forall l e a m b.
  (MonadIO m, MonadMask m) =>
  Observable l e a ->
  (Either (Ex e) a -> m ()) ->
  m b
observeBlocking obs code =
  observeWith obs \get -> forever (atomicallyC get >>= code)


-- ** Exception wrapper

type ObservableResult :: [Type] -> (Type -> Type) -> Type -> Type
data ObservableResult exceptions c v
  = ObservableResultOk (c v)
  | ObservableResultEx (Ex exceptions)

pattern ObservableResultTrivial :: c v -> ObservableResult '[] c v
pattern ObservableResultTrivial x <- (fromTrivialObservableResult -> x) where
  ObservableResultTrivial x = ObservableResultOk x

{-# COMPLETE ObservableResultTrivial #-}

fromTrivialObservableResult :: ObservableResult '[] c v -> c v
fromTrivialObservableResult (ObservableResultOk x) = x
fromTrivialObservableResult (ObservableResultEx ex) = absurdEx ex

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

instance Semigroup (c v) => Semigroup (ObservableResult canLoad c v) where
  ObservableResultOk x <> ObservableResultOk y = ObservableResultOk (x <> y)
  ObservableResultEx ex <> _fy = ObservableResultEx ex
  _fx <> ObservableResultEx ex = ObservableResultEx ex

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

instance ObservableContainer c v => ObservableContainer (ObservableResult exceptions c) v where
  type ContainerConstraint canLoad exceptions (ObservableResult exceptions c) v a = ContainerConstraint canLoad exceptions c v a
  type Delta (ObservableResult exceptions c) = Delta c
  type instance DeltaContext (ObservableResult exceptions c) = Maybe (DeltaContext c)
  type instance ValidatedDelta (ObservableResult exceptions c) = ValidatedDelta c
  applyDelta delta (ObservableResultOk content) = ObservableResultOk <$> applyDelta @c delta content
  -- NOTE This rejects deltas that are applied to an exception state. Beware
  -- that regardeless of this fact this still does count as a valid delta
  -- application, so it won't prevent the state transition from Loading to Live.
  applyDelta _delta x@(ObservableResultEx _ex) = Nothing
  mergeDelta old new = mergeDelta @c old new
  validateDelta (Just ctx) delta = validateDelta @c ctx delta
  validateDelta Nothing _delta = Nothing
  validatedDeltaToContext delta = Just (validatedDeltaToContext @c delta)
  validatedDeltaToDelta delta = validatedDeltaToDelta @c delta
  toDeltaContext (ObservableResultOk initial) = Just (toDeltaContext initial)
  toDeltaContext (ObservableResultEx _) = Nothing
