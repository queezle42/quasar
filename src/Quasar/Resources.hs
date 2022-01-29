module Quasar.Resources (
  Resource(..),
  Disposer,
  ResourceManager,
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
) where


import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.TOnce


class Resource a where
  getDisposer :: a -> Disposer


type DisposerState = TOnce DisposeFn (Awaitable ())

data Disposer
  = FnDisposer ExceptionChannel DisposerState Finalizers
  | ResourceManagerDisposer ResourceManager

data DisposeFn
  = IODisposeFn (IO ())
  | STMDisposeFn (STM ())

newDisposer :: ExceptionChannel -> IO () -> STM Disposer
newDisposer exChan disposeFn = newFnDisposer exChan (IODisposeFn disposeFn)

newSTMDisposer :: ExceptionChannel -> STM () -> STM Disposer
newSTMDisposer exChan disposeFn = newFnDisposer exChan (STMDisposeFn disposeFn)

newFnDisposer :: ExceptionChannel -> DisposeFn -> STM Disposer
newFnDisposer exChan fn =
  FnDisposer exChan <$> newTOnce fn <*> newFinalizersSTM


dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventuallySTM resource)

disposeEventuallySTM :: Resource r => r -> STM (Awaitable ())
disposeEventuallySTM resource =
  case getDisposer resource of
    FnDisposer channel state finalizers -> do
      beginDispose channel state finalizers
    ResourceManagerDisposer resourceManager ->
      beginDisposeResourceManager resourceManager

disposeEventuallySTM_ :: Resource r => r -> STM ()
disposeEventuallySTM_ resource = void $ disposeEventuallySTM resource


isDisposed :: Resource a => a -> Awaitable ()
isDisposed resource =
  case getDisposer resource of
    FnDisposer _ state _ -> join (toAwaitable state)
    ResourceManagerDisposer _resourceManager -> undefined -- resource manager


beginDispose :: ExceptionChannel -> DisposerState -> Finalizers -> STM (Awaitable ())
beginDispose channel disposeState finalizers =
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFn -> STM (Awaitable ())
    startDisposeFn = undefined -- launch dispose thread



data ResourceManager = ResourceManager

beginDisposeResourceManager :: ResourceManager -> STM (Awaitable ())
beginDisposeResourceManager = undefined -- resource manager



data DisposeResult
  = DisposeResultDisposed
  | DisposeResultAwait (Awaitable ())
  | DisposeResultResourceManager ResourceManagerResult

data ResourceManagerResult = ResourceManagerResult Unique (Awaitable [ResourceManagerResult])



-- * Implementation internals

newtype Finalizers = Finalizers (TMVar [STM ()])

newFinalizers :: IO Finalizers
newFinalizers = Finalizers <$> newTMVarIO []

newFinalizersSTM :: STM Finalizers
newFinalizersSTM = Finalizers <$> newTMVar []

defaultRegisterFinalizer :: Finalizers -> STM () -> STM Bool
defaultRegisterFinalizer (Finalizers finalizerVar) finalizer =
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> do
      putTMVar finalizerVar (finalizer : finalizers)
      pure True
    Nothing -> pure False

defaultRunFinalizers :: Finalizers -> STM ()
defaultRunFinalizers (Finalizers finalizerVar) = do
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> sequence_ finalizers
    Nothing -> throwM $ userError "defaultRunFinalizers was called multiple times (it must only be run once)"
