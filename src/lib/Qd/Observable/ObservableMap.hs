{-# LANGUAGE ViewPatterns #-}

module Qd.Observable.ObservableMap (
  ObservableMap,
  create,
  observeKey,
  insert,
  delete,
  lookupDelete,
) where

import Qd.Observable
import Qd.Utils.GetT

import Control.Concurrent.MVar
import qualified Data.HashMap.Strict as HM
import Data.Unique
import Prelude hiding (lookup, lookupDelete)

newtype ObservableMap k v = ObservableMap (MVar (HM.HashMap k (ObservableValue v)))

data ObservableValue v = ObservableValue {
  value :: Maybe v,
  subscribers :: (HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ()))
}

modifyValue :: forall k v a. (Eq k, Hashable k) => (ObservableValue v -> IO (ObservableValue v, a)) -> k -> ObservableMap k v -> IO a
modifyValue f k (ObservableMap mvar) = modifyMVar mvar $ \hashmap -> runGetT (HM.alterF update k hashmap)
  where
    update :: Maybe (ObservableValue v) -> GetT a IO (Maybe (ObservableValue v))
    update = fmap toMaybe . (GetT . f) . fromMaybe emptyObservableValue
    emptyObservableValue :: ObservableValue v
    emptyObservableValue = ObservableValue Nothing HM.empty
    toMaybe :: ObservableValue v -> Maybe (ObservableValue v)
    toMaybe (ObservableValue Nothing (HM.null -> True)) = Nothing
    toMaybe ov = Just ov

modifyValue_ :: forall k v. (Eq k, Hashable k) => (ObservableValue v -> IO (ObservableValue v)) -> k -> ObservableMap k v -> IO ()
modifyValue_ f = modifyValue (fmap (,()) . f)

modifySubscribers :: (HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ()) -> HM.HashMap Unique (ObservableMessage (Maybe v) -> IO ())) -> ObservableValue v -> ObservableValue v
modifySubscribers f ov@ObservableValue{subscribers} = ov{subscribers=f subscribers}

create :: IO (ObservableMap k v)
create = ObservableMap <$> newMVar HM.empty

observeKey :: forall k v. (Eq k, Hashable k) => k -> ObservableMap k v -> SomeObservable (Maybe v)
observeKey key om@(ObservableMap mvar) = SomeObservable FnObservable{getValueFn, subscribeFn}
  where
    getValueFn :: IO (Maybe v)
    getValueFn = (value <=< HM.lookup key) <$> readMVar mvar
    subscribeFn :: ((ObservableMessage (Maybe v) -> IO ()) -> IO SubscriptionHandle)
    subscribeFn callback = do
      subscriptionKey <- newUnique
      modifyValue_ (subscribeFn' subscriptionKey) key om
      return $ SubscriptionHandle $ unsubscribe subscriptionKey
      where
        subscribeFn' :: Unique -> ObservableValue v -> IO (ObservableValue v)
        subscribeFn' subKey ov@ObservableValue{value} = do
          callback (Current, value)
          return $ modifySubscribers (HM.insert subKey callback) ov
        unsubscribe :: Unique -> IO ()
        unsubscribe subKey = modifyValue_ (return . modifySubscribers (HM.delete subKey)) key om

insert :: forall k v. (Eq k, Hashable k) => k -> v -> ObservableMap k v -> IO ()
insert key value = modifyValue_ fn key
  where
    fn :: ObservableValue v -> IO (ObservableValue v)
    fn ov@ObservableValue{subscribers} = do
      mapM_ ($ (Update, Just value)) $ HM.elems subscribers
      return ov{value=Just value}

delete :: forall k v. (Eq k, Hashable k) => k -> ObservableMap k v -> IO ()
delete = modifyValue_ fn
  where
    fn :: ObservableValue v -> IO (ObservableValue v)
    fn ov@ObservableValue{subscribers} = do
      mapM_ ($ (Update, Nothing)) $ HM.elems subscribers
      return ov{value=Nothing}

lookupDelete :: forall k v. (Eq k, Hashable k) => k -> ObservableMap k v -> IO (Maybe v)
lookupDelete = modifyValue fn
  where
    fn :: ObservableValue v -> IO (ObservableValue v, Maybe v)
    fn ov@ObservableValue{value=oldValue, subscribers} = do
      mapM_ ($ (Update, Nothing)) $ HM.elems subscribers
      return (ov{value=Nothing}, oldValue)
