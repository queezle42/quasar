module Quasar.Utils.CallbackRegistry (
  CallbackRegistry,
  newCallbackRegistry,
  newCallbackRegistryIO,
  newCallbackRegistryWithEmptyCallback,
  registerCallback,
  callCallbacks,
  callbackRegistryHasCallbacks,
) where


import Control.Applicative
import Control.Monad.Except
import Data.HashMap.Strict qualified as HM
import Data.Unique
import Quasar.Prelude
import Quasar.Resources.Disposer

data CallbackRegistry a = CallbackRegistry (TVar (HM.HashMap Unique (a -> STMc NoRetry '[] ()))) (STMc NoRetry '[] ())

newCallbackRegistry :: STMc NoRetry '[] (CallbackRegistry a)
newCallbackRegistry = do
  var <- newTVar mempty
  pure $ CallbackRegistry var (pure ())

newCallbackRegistryWithEmptyCallback :: STMc NoRetry '[] () -> STMc NoRetry '[] (CallbackRegistry a)
newCallbackRegistryWithEmptyCallback emptyCallback = do
  var <- newTVar mempty
  pure $ CallbackRegistry var emptyCallback

newCallbackRegistryIO :: IO (CallbackRegistry a)
newCallbackRegistryIO = do
  var <- newTVarIO mempty
  pure $ CallbackRegistry var (pure ())

registerCallback :: CallbackRegistry a -> (a -> STMc NoRetry '[] ()) -> STMc NoRetry '[] TSimpleDisposer
registerCallback (CallbackRegistry var emptyCallback) callback = do
  key <- newUniqueSTM
  modifyTVar var (HM.insert key callback)
  newUnmanagedTSimpleDisposer do
    isEmpty <- HM.null <$> stateTVar var (dup . HM.delete key)
    when isEmpty emptyCallback

callCallbacks :: CallbackRegistry a -> a -> STMc NoRetry '[] ()
callCallbacks (CallbackRegistry var _) value = liftSTMc do
  mapM_ ($ value) . HM.elems =<< readTVar var

callbackRegistryHasCallbacks :: CallbackRegistry a -> STM Bool
callbackRegistryHasCallbacks (CallbackRegistry var _) =
  not . HM.null <$> readTVar var
