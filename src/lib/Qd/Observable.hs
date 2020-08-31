module Qd.Observable (
  SomeObservable(..),
  IsObservable(..),
  subscribe',
  SubscriptionHandle(..),
  Callback,
  ObservableState,
  ObservableMessage,
  MessageReason(..),
  BasicObservable,
  mkBasicObservable,
  setBasicObservable,
  updateBasicObservable,
) where

import Control.Concurrent.MVar
import Control.Monad.Fix (mfix)
import Data.Binary (Binary)
import qualified Data.HashMap.Strict as HM
import Data.Unique
import GHC.Generics (Generic)

data MessageReason = Current | Update
  deriving (Eq, Show, Generic)
instance Binary MessageReason

type ObservableState v = Maybe v
type ObservableMessage v = (MessageReason, ObservableState v)

mapObservableState :: Monad m => (a -> m b) -> ObservableState a -> m (ObservableState b)
mapObservableState _ Nothing = return Nothing
mapObservableState f (Just v) = Just <$> f v

mapObservableMessage :: Monad m => (a -> m b) -> ObservableMessage a -> m (ObservableMessage b)
mapObservableMessage f (r, s) = (r, ) <$> mapObservableState f s

newtype SubscriptionHandle = SubscriptionHandle { unsubscribe :: IO () }

class IsObservable v o | o -> v where
  getValue :: o -> IO (ObservableState v)
  subscribe :: o -> (ObservableMessage v -> IO ()) -> IO SubscriptionHandle
  mapObservable :: (v -> IO a) -> o -> SomeObservable a
  mapObservable f = SomeObservable . MappedObservable f

subscribe' :: IsObservable v o => o -> (SubscriptionHandle -> ObservableMessage v -> IO ()) -> IO SubscriptionHandle
subscribe' observable callback = mfix $ \subscription -> subscribe observable (callback subscription)

type Callback v = ObservableMessage v -> IO ()

-- | Existential quantification wrapper for the Observable type class.
data SomeObservable v = forall o. IsObservable v o => SomeObservable o
instance IsObservable v (SomeObservable v) where
  getValue (SomeObservable o) = getValue o
  subscribe (SomeObservable o) = subscribe o
  mapObservable f (SomeObservable o) = mapObservable f o

instance Functor SomeObservable where
  fmap f = mapObservable (return . f)

data MappedObservable b = forall a o. IsObservable a o => MappedObservable (a -> IO b) o
instance IsObservable v (MappedObservable v) where
  getValue (MappedObservable f observable) = mapObservableState f =<< getValue observable
  subscribe (MappedObservable f observable) callback = subscribe observable (callback <=< mapObservableMessage f)
  mapObservable f1 (MappedObservable f2 upstream) = SomeObservable $ MappedObservable (f1 <=< f2) upstream


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
  BasicObservable <$> newMVar (defaultValue, HM.empty)

setBasicObservable :: BasicObservable v -> v -> IO ()
setBasicObservable (BasicObservable mvar) value = do
  modifyMVar_ mvar $ \(_, subscribers) -> do
    let newState = Just value
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)

updateBasicObservable :: BasicObservable v -> (v -> v) -> IO ()
updateBasicObservable (BasicObservable mvar) f =
  modifyMVar_ mvar $ \(oldState, subscribers) -> do
    let newState = (\v -> f v) <$> oldState
    mapM_ (\callback -> callback (Update, newState)) subscribers
    return (newState, subscribers)
