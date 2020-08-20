module Qd.Observable (
  Observable,
  IsObservable(..),
  subscribe',
  SubscriptionHandle,
  unsubscribe,
  Callback,
  ObservableState,
  ObservableMessage,
  MessageReason(..),

  BasicObservable(..),
  Freshness(..),
  mkBasicObservable,
  staleBasicObservable,
  updateBasicObservable,
) where

import Control.Concurrent.MVar
import Control.Monad.Fix (mfix)
import qualified Data.HashMap.Strict as HM
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Unique

data Freshness = Fresh | Stale
  deriving (Eq, Show)
data MessageReason = Current | Update
  deriving (Eq, Show)

type ObservableState v = Maybe (v, Freshness, UTCTime)
type ObservableMessage v = (MessageReason, ObservableState v)

mapObservableState :: Monad m => (a -> m b) -> ObservableState a -> m (ObservableState b)
mapObservableState _ Nothing = return Nothing
mapObservableState f (Just (v, fr, t)) = Just . (, fr, t) <$> f v

mapObservableMessage :: Monad m => (a -> m b) -> ObservableMessage a -> m (ObservableMessage b)
mapObservableMessage f (r, s) = (r, ) <$> mapObservableState f s

newtype SubscriptionHandle = SubscriptionHandle (IO ())
unsubscribe :: SubscriptionHandle -> IO ()
unsubscribe (SubscriptionHandle unsubscribeAction) = unsubscribeAction

class IsObservable v o | o -> v where
  getValue :: o -> IO (ObservableState v)
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  mapObservable :: (v -> IO a) -> o -> Observable a
  mapObservable f = Observable . MappedObservable f

subscribe' :: IsObservable v o => o -> (SubscriptionHandle -> ObservableMessage v -> IO ()) -> IO SubscriptionHandle
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type Callback v = ObservableMessage v -> IO ()

-- | Wraps IsObservable in a concrete type
data Observable v = forall o. IsObservable v o => Observable o
instance IsObservable v (Observable v) where
  getValue (Observable o) = getValue o
  subscribe (Observable o) = subscribe o
  mapObservable f (Observable o) = mapObservable f o

instance Functor Observable where
  fmap f = mapObservable (return . f)

newtype BasicObservable v = BasicObservable (MVar (ObservableState v, HM.HashMap Unique (Callback v)))
instance IsObservable v (BasicObservable v) where
  getValue (BasicObservable mvar) = fst <$> readMVar mvar
  subscribe (BasicObservable mvar) callback = do
    key <- newUnique
    modifyMVar_ mvar $ \(state, subscribers) -> do
      -- Call listener
      callback (Current, state)
      return (state, HM.insert key callback subscribers)
    return $ SubscriptionHandle $ unsubscribe' key
    where
      unsubscribe' :: Unique -> IO ()
      unsubscribe' key = modifyMVar_ mvar $ \(state, subscribers) -> return (state, HM.delete key subscribers)

mkBasicObservable :: Maybe v -> IO (BasicObservable v)
mkBasicObservable defaultValue = do
  now <- getCurrentTime
  BasicObservable <$> newMVar ((, Fresh, now) <$> defaultValue, HM.empty)

staleBasicObservable :: BasicObservable v -> IO ()
staleBasicObservable (BasicObservable mvar) = do
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    let newState = (\(v, _, t) -> (v, Stale, t)) <$> oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)

updateBasicObservable :: forall v. BasicObservable v -> Maybe v -> IO ()
updateBasicObservable (BasicObservable mvar) value = do
  now <- getCurrentTime
  let newState = (, Fresh, now) <$> value
  modifyMVar_ mvar $ \(state, subscribers) -> do
    mapM_ (\callback -> callback (Update, state)) subscribers
    return (newState, subscribers)

data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> IO b) o
instance IsObservable v (MappedObservable v) where
  getValue (MappedObservable f observable) = mapObservableState f =<< getValue observable
  subscribe (MappedObservable f observable) callback = subscribe observable (callback <=< mapObservableMessage f)
  mapObservable f1 (MappedObservable f2 upstream) = Observable $ MappedObservable (f1 <=< f2) upstream
