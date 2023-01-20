{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Observable.Internal.ObserverRegistry (
  ObserverCallback,
  ObserverRegistry,
  newObserverRegistry,
  newObserverRegistryIO,
  newObserverRegistryWithEmptyCallback,
  registerObserver,
  updateObservers,
  observerRegistryHasObservers,
) where


import Control.Applicative
import Control.Monad.Except
import Data.HashMap.Strict qualified as HM
import Data.Unique
import Quasar.Prelude
import Quasar.Resources.Disposer

type ObserverCallback a = a -> STMc NoRetry '[] ()

data ObserverRegistry a = ObserverRegistry (TVar (HM.HashMap Unique (ObserverCallback a))) (STMc NoRetry '[] ())

newObserverRegistry :: STMc NoRetry '[] (ObserverRegistry a)
newObserverRegistry = do
  var <- newTVar mempty
  pure $ ObserverRegistry var (pure ())

newObserverRegistryWithEmptyCallback :: STMc NoRetry '[] () -> STMc NoRetry '[] (ObserverRegistry a)
newObserverRegistryWithEmptyCallback emptyCallback = do
  var <- newTVar mempty
  pure $ ObserverRegistry var emptyCallback

newObserverRegistryIO :: IO (ObserverRegistry a)
newObserverRegistryIO = do
  var <- newTVarIO mempty
  pure $ ObserverRegistry var (pure ())

registerObserver :: ObserverRegistry a -> ObserverCallback a -> a -> STMc NoRetry '[] TSimpleDisposer
registerObserver (ObserverRegistry var emptyCallback) callback currentValue = do
  key <- newUniqueSTM
  modifyTVar var (HM.insert key callback)
  disposer <- newUnmanagedTSimpleDisposer do
    isEmpty <- HM.null <$> stateTVar var (dup . HM.delete key)
    when isEmpty emptyCallback

  liftSTMc $ callback currentValue
  pure disposer

updateObservers :: ObserverRegistry a -> a -> STMc NoRetry '[] ()
updateObservers (ObserverRegistry var _) value = liftSTMc do
  mapM_ ($ value) . HM.elems =<< readTVar var

observerRegistryHasObservers :: ObserverRegistry a -> STM Bool
observerRegistryHasObservers (ObserverRegistry var _) =
  not . HM.null <$> readTVar var
