module Quasar.Pool (
  IsPool(..),
  Pool(..),
  newPool,
  addReconnectingPoolMember,
  mapPool,
) where

import Control.Monad.Catch (handleAll, mask_)
import Quasar.Async (unmanagedAsync)
import Quasar.Exceptions (ExceptionSink, throwToExceptionSinkIO)
import Quasar.Observable.Core
import Quasar.Observable.List (ObservableList)
import Quasar.Observable.Map (ObservableMapVar, toObservableMap)
import Quasar.Observable.Map qualified as ObservableMap
import Quasar.Prelude
import Quasar.Resources


-- TODO rename
data Pool a = forall b. IsPool a b => Pool b

instance IsPool a (Pool a) where
  addPoolMember (Pool pool) value = addPoolMember pool value


class IsPool a pool | pool -> a where
  addPoolMember :: pool -> a -> IO Disposer

data MappedPool b a = MappedPool (a -> b) (Pool b)

instance IsPool a (MappedPool b a) where
  addPoolMember (MappedPool fn pool) value = addPoolMember pool (fn value)


mapPool :: (a -> b) -> Pool b -> Pool a
mapPool fn pool = Pool (MappedPool fn pool)


data PoolVar a = PoolVar (TVar Word64) (ObservableMapVar Word64 a)

newPool :: MonadSTMc NoRetry '[] m => m (Pool a, ObservableList NoLoad '[] a)
newPool = liftSTMc @NoRetry @'[] do
  ctrVar <- newTVar 0
  poolVar <- ObservableMap.newVar mempty
  pure (Pool (PoolVar ctrVar poolVar), ObservableMap.values (toObservableMap poolVar))

instance IsPool a (PoolVar a) where
  addPoolMember (PoolVar ctrVar poolVar) value =
    atomically do
      ctr <- readTVar ctrVar
      let !nextCtr = ctr + 1
      writeTVar ctrVar nextCtr
      ObservableMap.insertVar poolVar ctr value
      getDisposer <$> newTDisposer do
        ObservableMap.deleteVar poolVar ctr

addReconnectingPoolMember :: ExceptionSink -> Observable l e (Pool a) -> a -> IO Disposer
addReconnectingPoolMember sink poolSource value = do
  currentDisposerVar <- newTVarIO mempty
  asyncDisposer <- unmanagedAsync sink (t currentDisposerVar)
  flip newDisposerIO sink do
    dispose asyncDisposer
    dispose =<< readTVarIO currentDisposerVar
  where
    t :: TVar Disposer -> IO ()
    t currentDisposerVar =
      observeBlocking poolSource \next -> do
        dispose =<< readTVarIO currentDisposerVar
        case next of
          Left ex -> throwToExceptionSinkIO sink (exToException ex)
          Right pool -> mask_ do
            handleAll (throwToExceptionSinkIO sink) do
              disposer <- addPoolMember pool value
              atomically $ writeTVar currentDisposerVar disposer

