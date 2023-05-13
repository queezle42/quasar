{-# LANGUAGE CPP #-}
{-# LANGUAGE UndecidableInstances #-}

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
{-# LANGUAGE TypeData #-}
#endif

module Quasar.Observable.Core (
  -- * Generalized observable
#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
  CanWait(..),
#else
  CanWait,
  Wait,
  NoWait,
#endif
) where

import Control.Applicative
import Control.Monad.Except
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.CallbackRegistry
import Quasar.Utils.Fix

-- * Generalized observables

type ToGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  toGeneralizedObservable :: a -> GeneralizedObservable canWait exceptions delta value
  default toGeneralizedObservable :: IsGeneralizedObservable canWait exceptions delta value a => a -> GeneralizedObservable canWait exceptions delta value
  toGeneralizedObservable = GeneralizedObservable

type IsGeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type -> Constraint
class ToGeneralizedObservable canWait exceptions delta value a => IsGeneralizedObservable canWait exceptions delta value a | a -> canWait, a -> exceptions, a -> value, a -> delta where
  {-# MINIMAL readObservable#, (attachObserver# | attachStateObserver#) #-}
  readObservable# :: a -> STMc NoRetry '[] (Final, ObservableState canWait exceptions value)

  attachObserver# :: a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachObserver# x callback = attachStateObserver# x \final changeWithState ->
    callback final case changeWithState of
      ObservableChangeWithStateWaiting _ -> ObservableChangeWaiting
      ObservableChangeWithStateUpdate delta _ -> ObservableChangeUpdate delta

  attachStateObserver# :: a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> STMc NoRetry '[] (TSimpleDisposer, Final, ObservableState canWait exceptions value)
  attachStateObserver# x callback =
    mfixTVar \var -> do
      (disposer, final, initial) <- attachObserver# x \final change -> do
        merged <- stateTVar var \oldState ->
          let merged = applyObservableChange change oldState
          in (merged, changeWithStateToState merged)
        callback final merged
      pure ((disposer, final, initial), initial)

  isCachedObservable# :: a -> Bool
  isCachedObservable# _ = False

  mapObservable# :: (value -> n) -> a -> Observable canWait exceptions n
  mapObservable# f (evaluateObservable# -> Some x) = Observable (GeneralizedObservable (MappedObservable f x))

  mapObservableDelta# :: IsObservableDelta newDelta newValue => (delta -> newDelta) -> (value -> newValue) -> a -> GeneralizedObservable canWait exceptions newDelta newValue
  mapObservableDelta# fd fn x = GeneralizedObservable (DeltaMappedObservable fd fn x)

readObservable
  :: (ToGeneralizedObservable NoWait exceptions delta value a, MonadSTMc NoRetry exceptions m, ExceptionList exceptions)
  => a -> m value
readObservable x = case toGeneralizedObservable x of
  (ConstObservable state) -> extractState state
  (GeneralizedObservable y) -> do
    (_final, state) <- liftSTMc $ readObservable# y
    extractState state
  where
    extractState :: (MonadSTMc NoRetry exceptions m, ExceptionList exceptions) => ObservableState NoWait exceptions a -> m a
    extractState (ObservableStateValue z) = either throwEx pure z

attachObserver :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChange canWait exceptions delta -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

attachStateObserver :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> (Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()) -> m (TSimpleDisposer, Final, ObservableState canWait exceptions value)
attachStateObserver x callback = liftSTMc
  case toGeneralizedObservable x of
    GeneralizedObservable f -> attachStateObserver# f callback
    ConstObservable c -> pure (mempty, True, c)

isCachedObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Bool
isCachedObservable x = case toGeneralizedObservable x of
  GeneralizedObservable notConst -> isCachedObservable# notConst
  ConstObservable _value -> True

mapObservable :: ToGeneralizedObservable canWait exceptions delta value a => (value -> f) -> a -> Observable canWait exceptions f
mapObservable fn x = case toGeneralizedObservable x of
  (GeneralizedObservable x) -> mapObservable# fn x
  (ConstObservable state) -> Observable (ConstObservable (fn <$> state))

type Final = Bool

#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
type data CanWait = Wait | NoWait
#else
data CanWait = Wait | NoWait
type Wait = 'Wait
type NoWait = 'NoWait
#endif

type ObservableChange :: CanWait -> [Type] -> Type -> Type
data ObservableChange canWait exceptions delta where
  ObservableChangeWaiting :: ObservableChange Wait exceptions delta
  ObservableChangeUpdate :: Maybe (Either (Ex exceptions) delta) -> ObservableChange canWait exceptions delta

type ObservableState :: CanWait -> [Type] -> Type -> Type
data ObservableState canWait exceptions value where
  ObservableStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableState Wait exceptions value
  ObservableStateValue :: Either (Ex exceptions) value -> ObservableState canWait exceptions value

type ObservableChangeWithState :: CanWait -> [Type] -> Type -> Type -> Type
data ObservableChangeWithState canWait exceptions delta value where
  ObservableChangeWithStateWaiting :: Maybe (Either (Ex exceptions) value) -> ObservableChangeWithState Wait exceptions delta value
  ObservableChangeWithStateUpdate :: Maybe (Either (Ex exceptions) delta) -> Either (Ex exceptions) value -> ObservableChangeWithState canWait exceptions delta value

instance Functor (ObservableChange canWait exceptions) where
  fmap _ ObservableChangeWaiting = ObservableChangeWaiting
  fmap fn (ObservableChangeUpdate x) = ObservableChangeUpdate (fn <<$>> x)

instance Functor (ObservableState canWait exceptions) where
  fmap fn (ObservableStateWaiting x) = ObservableStateWaiting (fn <<$>> x)
  fmap fn (ObservableStateValue x) = ObservableStateValue (fn <$> x)

applyObservableChange :: IsObservableDelta delta value => ObservableChange canWait exceptions delta -> ObservableState canWait exceptions value -> ObservableChangeWithState canWait exceptions delta value
-- Set to loading
applyObservableChange ObservableChangeWaiting (ObservableStateValue x) = ObservableChangeWithStateWaiting (Just x)
applyObservableChange ObservableChangeWaiting (ObservableStateWaiting x) = ObservableChangeWithStateWaiting x
-- Reactivate old value
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateWaiting (Just x)) = ObservableChangeWithStateUpdate Nothing x
-- NOTE: An update is ignored for uncached waiting state.
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateWaiting Nothing) = ObservableChangeWithStateWaiting Nothing
applyObservableChange (ObservableChangeUpdate Nothing) (ObservableStateValue x) = ObservableChangeWithStateUpdate Nothing x
-- Update with exception delta
applyObservableChange (ObservableChangeUpdate delta@(Just (Left x))) _ = ObservableChangeWithStateUpdate delta (Left x)
-- Update with value delta
applyObservableChange (ObservableChangeUpdate delta@(Just (Right x))) y =
  ObservableChangeWithStateUpdate delta (Right (applyDelta x (getStateValue y)))
  where
    getStateValue :: ObservableState canWait exceptions a -> Maybe a
    getStateValue (ObservableStateWaiting (Just (Right value))) = Just value
    getStateValue (ObservableStateValue (Right value)) = Just value
    getStateValue _ = Nothing

changeWithStateToState :: ObservableChangeWithState canWait exceptions delta value -> ObservableState canWait exceptions value
changeWithStateToState (ObservableChangeWithStateWaiting cached) = ObservableStateWaiting cached
changeWithStateToState (ObservableChangeWithStateUpdate _delta value) = ObservableStateValue value


type GeneralizedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data GeneralizedObservable canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => GeneralizedObservable a
  | ConstObservable (ObservableState canWait exceptions value)

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (GeneralizedObservable canWait exceptions delta value) where
  toGeneralizedObservable = id

class IsObservableDelta delta value where
  applyDelta :: delta -> Maybe value -> value
  mergeDelta :: delta -> delta -> delta

  evaluateObservable# :: IsGeneralizedObservable canWait exceptions delta value a => a -> Some (IsObservable canWait exceptions value)
  evaluateObservable# x = Some (EvaluatedObservable x)

  toObservable :: ToGeneralizedObservable canWait exceptions delta value a => a -> Observable canWait exceptions value
  toObservable x = Observable
    case toGeneralizedObservable x of
      (GeneralizedObservable f) -> GeneralizedObservable (EvaluatedObservable f)
      (ConstObservable c) -> ConstObservable c

instance IsObservableDelta a a where
  applyDelta new _ = new
  mergeDelta _ new = new
  evaluateObservable# x = Some x
  toObservable x = Observable (toGeneralizedObservable x)


type EvaluatedObservable :: CanWait -> [Type] -> Type -> Type -> Type
data EvaluatedObservable canWait exceptions delta value = forall a. IsGeneralizedObservable canWait exceptions delta value a => EvaluatedObservable a

instance ToGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value)

instance IsGeneralizedObservable canWait exceptions value value (EvaluatedObservable canWait exceptions delta value) where
  readObservable# (EvaluatedObservable x) = readObservable# x
  attachStateObserver# (EvaluatedObservable x) callback =
    attachStateObserver# x \final changeWithState ->
      callback final case changeWithState of
        ObservableChangeWithStateWaiting cache -> ObservableChangeWithStateWaiting cache
        -- Replace delta with evaluated value
        ObservableChangeWithStateUpdate _delta content -> ObservableChangeWithStateUpdate (Just content) content


data DeltaMappedObservable canWait exceptions delta value = forall oldDelta oldValue a. IsGeneralizedObservable canWait exceptions oldDelta oldValue a => DeltaMappedObservable (oldDelta -> delta) (oldValue -> value) a

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value)

instance IsObservableDelta delta value => IsGeneralizedObservable canWait exceptions delta value (DeltaMappedObservable canWait exceptions delta value) where
  attachObserver# (DeltaMappedObservable deltaFn valueFn observable) callback =
    fmap3 valueFn $ attachObserver# observable \final change ->
      callback final (deltaFn <$> change)
  readObservable# (DeltaMappedObservable _deltaFn valueFn observable) =
    fmap3 valueFn $ readObservable# observable
  mapObservableDelta# fd1 fn1 (DeltaMappedObservable fd2 fn2 x) = GeneralizedObservable (DeltaMappedObservable (fd1 . fd2) (fn1 . fn2) x)


-- ** Cache

newtype CachedObservable canWait exceptions delta value = CachedObservable (TVar (CacheState canWait exceptions delta value))

data CacheState canWait exceptions delta value
  = forall a. IsGeneralizedObservable canWait exceptions delta value a => CacheIdle a
  | forall a. IsGeneralizedObservable canWait exceptions delta value a =>
    CacheAttached
      a
      TSimpleDisposer
      (CallbackRegistry (Final, ObservableChangeWithState canWait exceptions delta value))
      (ObservableState canWait exceptions value)
  | CacheFinalized (ObservableState canWait exceptions value)

instance IsObservableDelta delta value => ToGeneralizedObservable canWait exceptions delta value (CachedObservable canWait exceptions delta value)

instance IsObservableDelta delta value => IsGeneralizedObservable canWait exceptions delta value (CachedObservable canWait exceptions delta value) where
  readObservable# (CachedObservable var) = do
    readTVar var >>= \case
      CacheIdle x -> readObservable# x
      CacheAttached _x _disposer _registry state -> pure (False, state)
      CacheFinalized state -> pure (True, state)
  attachStateObserver# (CachedObservable var) callback = do
    readTVar var >>= \case
      CacheIdle upstream -> do
        registry <- newCallbackRegistryWithEmptyCallback removeCacheListener
        (upstreamDisposer, final, value) <- attachStateObserver# upstream updateCache
        writeTVar var (CacheAttached upstream upstreamDisposer registry value)
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, final, value)
      CacheAttached _ _ registry value -> do
        disposer <- registerCallback registry (uncurry callback)
        pure (disposer, False, value)
      CacheFinalized value -> pure (mempty, True, value)
    where
      removeCacheListener :: STMc NoRetry '[] ()
      removeCacheListener = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer _ _ -> do
            writeTVar var (CacheIdle upstream)
            disposeTSimpleDisposer upstreamDisposer
          CacheFinalized _ -> pure ()
      updateCache :: Final -> ObservableChangeWithState canWait exceptions delta value -> STMc NoRetry '[] ()
      updateCache final change = do
        readTVar var >>= \case
          CacheIdle _ -> unreachableCodePath
          CacheAttached upstream upstreamDisposer registry _ ->
            if final
              then do
                writeTVar var (CacheFinalized (changeWithStateToState change))
                callCallbacks registry (final, change)
                clearCallbackRegistry registry
              else do
                writeTVar var (CacheAttached upstream upstreamDisposer registry (changeWithStateToState change))
                callCallbacks registry (final, change)
          CacheFinalized _ -> pure () -- Upstream implementation error

  isCachedObservable# _ = True

cacheObservable :: (ToGeneralizedObservable canWait exceptions delta value a, MonadSTMc NoRetry '[] m) => a -> m (GeneralizedObservable canWait exceptions delta value)
cacheObservable x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    y@(GeneralizedObservable f) ->
      if isCachedObservable# f
        then pure y
        else GeneralizedObservable . CachedObservable <$> newTVar (CacheIdle f)


-- *** Embedded cache in the Observable monad

data CacheObservableOperation canWait exceptions w e d v = forall a. ToGeneralizedObservable w e d v a => CacheObservableOperation a

instance ToGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v)

instance IsGeneralizedObservable canWait exceptions (GeneralizedObservable w e d v) (GeneralizedObservable w e d v) (CacheObservableOperation canWait exceptions w e d v) where
  readObservable# (CacheObservableOperation x) = do
    cache <- cacheObservable x
    pure (True, ObservableStateValue (Right cache))
  attachObserver# (CacheObservableOperation x) _callback = do
    cache <- cacheObservable x
    pure (mempty, True, ObservableStateValue (Right cache))

-- | Cache an observable in the `Observable` monad. Use with care! A new cache
-- is recreated whenever the result of this function is reevaluated.
cacheObservableOperation :: forall canWait exceptions w e d v a. ToGeneralizedObservable w e d v a => a -> Observable canWait exceptions (GeneralizedObservable w e d v)
cacheObservableOperation x =
  case toGeneralizedObservable x of
    c@(ConstObservable _) -> pure c
    (GeneralizedObservable f) -> Observable (GeneralizedObservable (CacheObservableOperation @canWait @exceptions f))


-- ** Observable

type Observable :: CanWait -> [Type] -> Type -> Type
newtype Observable canWait exceptions a = Observable (GeneralizedObservable canWait exceptions a a)
type ToObservable canWait exceptions a = ToGeneralizedObservable canWait exceptions a a
type IsObservable canWait exceptions a = IsGeneralizedObservable canWait exceptions a a

instance ToGeneralizedObservable canWait exceptions value value (Observable canWait exceptions value) where
  toGeneralizedObservable (Observable x) = x

instance Functor (Observable canWait exceptions) where
  fmap f (Observable x) = mapObservable f x

instance Applicative (Observable canWait exceptions) where
  pure value = Observable (ConstObservable (ObservableStateValue (Right value)))
  liftA2 = undefined

instance Monad (Observable canWait exceptions) where
  (>>=) = undefined


data MappedObservable canWait exceptions value = forall prev a. IsObservable canWait exceptions prev a => MappedObservable (prev -> value) a

instance ToGeneralizedObservable canWait exceptions value value (MappedObservable canWait exceptions value)

instance IsGeneralizedObservable canWait exceptions value value (MappedObservable canWait exceptions value) where
  attachObserver# (MappedObservable fn observable) callback =
    fmap3 fn $ attachObserver# observable \final change ->
      callback final (fn <$> change)
  readObservable# (MappedObservable fn observable) =
    fmap3 fn $ readObservable# observable
  mapObservable# f1 (MappedObservable f2 upstream) =
    toObservable $ MappedObservable (f1 . f2) upstream


-- * Some

data Some c = forall a. c a => Some a
