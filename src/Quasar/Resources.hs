module Quasar.Resources (
  Resource(..),
  Disposer,
  ResourceManager,
  dispose,
  disposeEventuallySTM,
  disposeEventuallySTM_,
  isDisposed,
  newPrimitiveDisposer,
) where


import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.TOnce


class Resource a where
  getDisposer :: a -> Disposer


type DisposerState = TOnce DisposeFn (Awaitable ())

data Disposer
  = FnDisposer Unique TIOWorker ExceptionChannel DisposerState Finalizers
  | ResourceManagerDisposer ResourceManager

type DisposeFn = IO (Awaitable ())

newShortDisposer :: TIOWorker -> ExceptionChannel -> IO () -> STM Disposer
newShortDisposer worker exChan disposeFn = newPrimitiveDisposer worker exChan (pure <$> disposeFn)

newShortSTMDisposer :: TIOWorker -> ExceptionChannel -> STM () -> STM Disposer
newShortSTMDisposer worker exChan disposeFn = newShortDisposer worker exChan (atomically disposeFn)

-- TODO document: IO has to be "short"
newPrimitiveDisposer :: TIOWorker -> ExceptionChannel -> IO (Awaitable ()) -> STM Disposer
newPrimitiveDisposer worker exChan fn = do
  key <- newUniqueSTM
  FnDisposer key worker exChan <$> newTOnce fn <*> newFinalizers


dispose :: (MonadIO m, Resource r) => r -> m ()
dispose resource = liftIO $ await =<< atomically (disposeEventuallySTM resource)

disposeEventuallySTM :: Resource r => r -> STM (Awaitable ())
disposeEventuallySTM resource =
  case getDisposer resource of
    FnDisposer _ worker exChan state finalizers -> do
      beginDisposeFnDisposer worker exChan state finalizers
    ResourceManagerDisposer resourceManager -> undefined

disposeEventuallySTM_ :: Resource r => r -> STM ()
disposeEventuallySTM_ resource = void $ disposeEventuallySTM resource


isDisposed :: Resource a => a -> Awaitable ()
isDisposed resource =
  case getDisposer resource of
    FnDisposer _ state _ -> join (toAwaitable state)
    ResourceManagerDisposer _resourceManager -> undefined -- resource manager


beginDisposeFnDisposer :: TIOWorker -> ExceptionChannel -> DisposerState -> Finalizers -> STM (Awaitable ())
beginDisposeFnDisposer worker exChan disposeState finalizers =
  mapFinalizeTOnce disposeState startDisposeFn
  where
    startDisposeFn :: DisposeFn -> STM (Awaitable ())
    startDisposeFn disposeFn = do
      awaitableVar <- newAsyncVarSTM
      startTrivialIO_ worker exChan (runDisposeFn awaitableVar disposeFn)
      pure $ join (toAwaitable awaitableVar)

    runDisposeFn :: AsyncVar (Awaitable ()) -> DisposeFn -> IO ()
    runDisposeFn awaitableVar disposeFn = mask_ $ handleAll exceptionHandler do
      awaitable <- disposeFn 
      putAsyncVar_ awaitableVar awaitable
      runFinalizersAfter finalizers awaitable
      where
        exceptionHandler :: SomeException -> IO ()
        exceptionHandler ex = do
          -- In case of an exception mark disposable as completed to prevent resource managers from being stuck indefinitely
          putAsyncVar_ awaitableVar (pure ())
          atomically $ runFinalizers finalizers
          throwIO $ DisposeException ex


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

newFinalizers :: STM Finalizers
newFinalizers = do
  Finalizers <$> newTMVar []

registerFinalizer :: Finalizers -> STM () -> STM Bool
registerFinalizer (Finalizers finalizerVar) finalizer =
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> do
      putTMVar finalizerVar (finalizer : finalizers)
      pure True
    Nothing -> pure False

runFinalizers :: Finalizers -> STM ()
runFinalizers (Finalizers finalizerVar) = do
  tryTakeTMVar finalizerVar >>= \case
    Just finalizers -> sequence_ finalizers
    Nothing -> throwM $ userError "runFinalizers was called multiple times (it must only be run once)"

runFinalizersAfter :: Finalizers -> Awaitable () -> IO ()
runFinalizersAfter finalizers awaitable = do
  -- Peek awaitable to ensure trivial disposables always run without forking
  isCompleted <- isJust <$> peekAwaitable awaitable 
  if isCompleted
    then
      atomically $ runFinalizers finalizers
    else
      void $ forkIO do
        await awaitable
        atomically $ runFinalizers finalizers
