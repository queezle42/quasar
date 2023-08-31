{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.Core (
  -- * CallbackRegistry
  CallbackRegistry,
  newCallbackRegistry,
  newCallbackRegistryIO,
  newCallbackRegistryWithEmptyCallback,
  registerCallback,
  registerCallbackChangeAfterFirstCall,
  callCallbacks,
  callbackRegistryHasCallbacks,
  clearCallbackRegistry,

  -- * TSimpleDisposer
  TSimpleDisposerState(..),
  TSimpleDisposerElement(..),
  TSimpleDisposer(..),
  newUnmanagedTSimpleDisposer,
  disposeTSimpleDisposer,
  disposeTSimpleDisposerElement,
) where


import Control.Applicative
import Control.Monad.Except
import Data.HashMap.Strict qualified as HM
import Data.Unique
import Quasar.Prelude

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

-- | Registeres a callback (like `registerCallback`) that is replaced with
-- another callback after the first invocation.
registerCallbackChangeAfterFirstCall ::
  forall a.
  CallbackRegistry a ->
  (a -> STMc NoRetry '[] ()) ->
  (a -> STMc NoRetry '[] ()) ->
  STMc NoRetry '[] TSimpleDisposer
registerCallbackChangeAfterFirstCall (CallbackRegistry var emptyCallback) firstCallback otherCallback = do
  key <- newUniqueSTM
  modifyTVar var (HM.insert key (wrappedCallback key))
  newUnmanagedTSimpleDisposer do
    isEmpty <- HM.null <$> stateTVar var (dup . HM.delete key)
    when isEmpty emptyCallback
  where
    wrappedCallback :: Unique -> (a -> STMc NoRetry '[] ())
    wrappedCallback key value = do
      oldCallbacks <- readTVar var
      -- Needs to check for an active membership in case an earlier callback
      -- called the disposer during the current `callCallbacks`.
      when (HM.member key oldCallbacks) do
        writeTVar var (HM.insert key otherCallback oldCallbacks)
      firstCallback value

callCallbacks :: CallbackRegistry a -> a -> STMc NoRetry '[] ()
callCallbacks (CallbackRegistry var _) value = liftSTMc do
  mapM_ ($ value) . HM.elems =<< readTVar var

callbackRegistryHasCallbacks :: MonadSTMc NoRetry '[] m => CallbackRegistry a -> m Bool
callbackRegistryHasCallbacks (CallbackRegistry var _) =
  not . HM.null <$> readTVar var

clearCallbackRegistry :: CallbackRegistry a -> STMc NoRetry '[] ()
clearCallbackRegistry (CallbackRegistry var emptyCallback) = do
  wasEmpty <- HM.null <$> readTVar var
  writeTVar var HM.empty
  -- TODO in the future if dropped disposers are detected we would have to
  -- dispose all disposers belonging to the registry
  unless wasEmpty emptyCallback


data TSimpleDisposerState
  = TSimpleDisposerNormal (STMc NoRetry '[] ()) (CallbackRegistry ())
  | TSimpleDisposerDisposing (CallbackRegistry ())
  | TSimpleDisposerDisposed

data TSimpleDisposerElement = TSimpleDisposerElement Unique (TVar TSimpleDisposerState)

newtype TSimpleDisposer = TSimpleDisposer [TSimpleDisposerElement]
  deriving newtype (Semigroup, Monoid)

newUnmanagedTSimpleDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TSimpleDisposer
newUnmanagedTSimpleDisposer fn = liftSTMc do
  key <- newUniqueSTM
  isDisposedRegistry <- newCallbackRegistry
  stateVar <- newTVar (TSimpleDisposerNormal fn isDisposedRegistry)
  let element = TSimpleDisposerElement key stateVar
  pure $ TSimpleDisposer [element]

-- | In case of reentry this will return without calling the dispose hander again.
disposeTSimpleDisposer :: MonadSTMc NoRetry '[] m => TSimpleDisposer -> m ()
disposeTSimpleDisposer (TSimpleDisposer elements) = liftSTMc do
  mapM_ disposeTSimpleDisposerElement elements

-- | In case of reentry this will return without calling the dispose hander again.
disposeTSimpleDisposerElement :: TSimpleDisposerElement -> STMc NoRetry '[] ()
disposeTSimpleDisposerElement (TSimpleDisposerElement _ state) =
  readTVar state >>= \case
    TSimpleDisposerNormal fn isDisposedRegistry -> do
      writeTVar state (TSimpleDisposerDisposing isDisposedRegistry)
      fn
      writeTVar state TSimpleDisposerDisposed
      callCallbacks isDisposedRegistry ()
    TSimpleDisposerDisposing _ ->
      -- Doing nothing results in the documented behavior.
      pure ()
    TSimpleDisposerDisposed -> pure ()
