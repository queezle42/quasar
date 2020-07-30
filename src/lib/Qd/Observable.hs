module Qd.Observable where

import Control.Concurrent.MVar
import Data.List (delete)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Unique

data Freshness = Fresh | Stale
data MessageReason = Current | Update

type ObservableState v = Maybe (v, Freshness, UTCTime)
type ObservableMessage v = (MessageReason, ObservableState v)


data Listener v = Listener Unique (ObservableMessage v -> IO ())
instance Eq (Listener v) where
  Listener a _ == Listener b _ = a == b

createListener :: (ObservableMessage v -> IO ()) -> IO (Listener v)
createListener f = Listener <$> newUnique <*> (return f)

class IsObservable v o where
  getValue :: o -> IO (ObservableState v)
  subscribe :: o -> Listener v -> IO ()
  unsubscribe :: o -> Listener v -> IO ()

-- | Wraps IsObservable in a concrete type
data Observable v = forall o. IsObservable v o => Observable o
instance IsObservable v (Observable v) where
  getValue (Observable o) = getValue o
  subscribe (Observable o) = subscribe o
  unsubscribe (Observable o) = unsubscribe o

newtype BasicObservable v = BasicObservable (MVar (ObservableState v, [Listener v]))
instance IsObservable v (BasicObservable v) where
  getValue (BasicObservable mvar) = fst <$> readMVar mvar
  subscribe (BasicObservable mvar) listener@(Listener _ callback) = do
    modifyMVar_ mvar $ \(state, listeners) -> do
      -- Call listener
      callback (Current, state)
      return (state, listener:listeners)
  unsubscribe (BasicObservable mvar) listener = modifyMVar_ mvar $ \(state, listeners) -> return (state, delete listener listeners)

mkBasicObservable :: Maybe v -> IO (BasicObservable v)
mkBasicObservable defaultValue = do
  now <- getCurrentTime
  BasicObservable <$> newMVar ((, Fresh, now) <$> defaultValue, [])

staleBasicObservable :: BasicObservable v -> IO ()
staleBasicObservable (BasicObservable mvar) = do
  modifyMVar_ mvar $ \(oldState, listeners) -> do
    let newState = (\(v, _, t) -> (v, Stale, t)) <$> oldState
    mapM_ (\(Listener _ callback) -> callback (Update, newState)) listeners
    return (newState, listeners)

updateBasicObservable :: forall v. BasicObservable v -> Maybe v -> IO ()
updateBasicObservable (BasicObservable mvar) value = do
  now <- getCurrentTime
  let newState = (, Fresh, now) <$> value
  modifyMVar_ mvar $ \(state, listeners) -> do
    mapM_ (\(Listener _ callback) -> callback (Update, state)) listeners
    return (newState, listeners)

mapObservable :: (a -> b) -> Observable a -> Observable b
mapObservable = undefined

mapMObservable :: (a -> IO b) -> Observable a -> Observable b
mapMObservable = undefined
