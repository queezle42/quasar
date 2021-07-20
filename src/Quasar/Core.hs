module Quasar.Core (
  -- * Async
  IsAsync(..),
  Async,
  successfulAsync,
  failedAsync,
  completedAsync,

  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  startAsyncIO,

  -- * AsyncVar
  AsyncVar,
  newAsyncVar,
  putAsyncVar,

  -- * Disposable
  IsDisposable(..),
  disposeIO,
  disposeEventually,
  Disposable,
  mkDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Control.Exception (try)
import Data.HashMap.Strict qualified as HM
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait x = do
    mvar <- newEmptyMVar
    onResult_ x (resultCallback mvar)
    readMVar mvar >>= either throwIO pure
    where
      resultCallback :: MVar (Either SomeException r) -> Either SomeException r -> IO ()
      resultCallback mvar result = do
        success <- tryPutMVar mvar result
        unless success $ fail "Callback was called multiple times"

  peekAsync :: a -> IO (Maybe (Either SomeException r))

  -- | Register a callback, that will be called once the promise is settled.
  -- If the promise is already settled, the callback will be called immediately instead.
  --
  -- The returned `Disposable` can be used to deregister the callback.
  onResult
    :: a
    -- ^ async
    -> (Either SomeException r -> IO ())
    -- ^ callback
    -> IO Disposable

  onResult_ :: a -> (Either SomeException r -> IO ()) -> IO ()
  onResult_ x = void . onResult x

  toAsync :: a -> Async r
  toAsync = SomeAsync



data Async r = forall a. IsAsync r a => SomeAsync a

instance IsAsync r (Async r) where
  wait (SomeAsync x) = wait x
  onResult (SomeAsync x) = onResult x
  onResult_ (SomeAsync x) = onResult_ x
  peekAsync (SomeAsync x) = peekAsync x
  toAsync = id


newtype CompletedAsync r = CompletedAsync (Either SomeException r)
instance IsAsync r (CompletedAsync r) where
  wait (CompletedAsync value) = either throwIO pure value
  onResult (CompletedAsync value) callback = noDisposable <$ callback value
  peekAsync (CompletedAsync value) = pure $ Just value

completedAsync :: Either SomeException r -> Async r
completedAsync = toAsync . CompletedAsync

successfulAsync :: r -> Async r
successfulAsync = completedAsync . Right

failedAsync :: SomeException -> Async r
failedAsync = completedAsync . Left


-- * AsyncIO

newtype AsyncIO r = AsyncIO (IO (Async r))

instance Functor AsyncIO where
  fmap f = (pure . f =<<)

instance Applicative AsyncIO where
  pure = await . successfulAsync
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py
instance Monad AsyncIO where
  lhs >>= fn = AsyncIO $ do
    resultVar <- newAsyncVar
    lhsAsync <- startAsyncIO lhs
    lhsAsync `onResult_` \case
      Right lhsResult -> do
        rhsAsync <- startAsyncIO $ fn lhsResult
        rhsAsync `onResult_` putAsyncVarEither resultVar
      Left lhsEx -> putAsyncVarEither resultVar (Left lhsEx)
    pure $ toAsync resultVar

instance MonadIO AsyncIO where
  liftIO = AsyncIO . fmap completedAsync . try


-- | Run the synchronous part of an `AsyncIO` and then return an `Async` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Async r)
async = liftIO . startAsyncIO

await :: IsAsync r a => a -> AsyncIO r
await = AsyncIO . pure . toAsync

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO = startAsyncIO >=> wait


-- | Run the synchronous part of an `AsyncIO`. Returns an `Async` that can be used to wait for completion of the operation.
startAsyncIO :: AsyncIO r -> IO (Async r)
startAsyncIO (AsyncIO x) = x

-- ** Forking asyncs

-- TODO
--class IsAsyncForkable m where
--  asyncThread :: m r -> AsyncIO r


-- * Async helpers

-- ** AsyncVar

-- | The default implementation for a `Async` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (MVar (AsyncVarState r))
data AsyncVarState r = AsyncVarCompleted (Either SomeException r) | AsyncVarOpen (HM.HashMap Unique (Either SomeException r -> IO ()))

instance IsAsync r (AsyncVar r) where
  peekAsync :: AsyncVar r -> IO (Maybe (Either SomeException r))
  peekAsync (AsyncVar mvar) = readMVar mvar >>= pure . \case
    AsyncVarCompleted x -> Just x
    AsyncVarOpen _ -> Nothing

  onResult :: AsyncVar r -> (Either SomeException r -> IO ()) -> IO Disposable
  onResult (AsyncVar mvar) callback =
    modifyMVar mvar $ \case
      AsyncVarOpen callbacks -> do
        key <- newUnique
        pure (AsyncVarOpen (HM.insert key callback callbacks), removeHandler key)
      x@(AsyncVarCompleted value) -> (x, noDisposable) <$ callback value
    where
      removeHandler :: Unique -> Disposable
      removeHandler key = synchronousDisposable $ modifyMVar_ mvar $ pure . \case
        x@(AsyncVarCompleted _) -> x
        AsyncVarOpen x -> AsyncVarOpen $ HM.delete key x


newAsyncVar :: MonadIO m => m (AsyncVar r)
newAsyncVar = liftIO $ AsyncVar <$> newMVar (AsyncVarOpen HM.empty)

putAsyncVar :: MonadIO m => AsyncVar a -> a -> m ()
putAsyncVar asyncVar = putAsyncVarEither asyncVar . Right

putAsyncVarEither :: MonadIO m => AsyncVar a -> Either SomeException a -> m ()
putAsyncVarEither (AsyncVar mvar) value = liftIO $ do
  modifyMVar_ mvar $ \case
    AsyncVarCompleted _ -> fail "An AsyncVar can only be fulfilled once"
    AsyncVarOpen callbacksMap -> do
      let callbacks = HM.elems callbacksMap
      -- NOTE disposing a callback while it is called is a deadlock
      mapM_ ($ value) callbacks
      pure (AsyncVarCompleted value)


-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource.
  dispose :: a -> AsyncIO ()

  toDisposable :: a -> Disposable
  toDisposable = mkDisposable . dispose

-- | Dispose a resource in the IO monad.
disposeIO :: IsDisposable a => a -> IO ()
disposeIO = runAsyncIO . dispose

-- | Dispose a resource. Returns without waiting for the resource to be released if possible.
disposeEventually :: IsDisposable a => a -> IO ()
disposeEventually = void . startAsyncIO . dispose

instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose


newtype Disposable = Disposable (AsyncIO ())

instance IsDisposable Disposable where
  dispose (Disposable fn) = fn
  toDisposable = id

instance Semigroup Disposable where
  x <> y = mkDisposable $ liftA2 (<>) (dispose x) (dispose y)

instance Monoid Disposable where
  mempty = mkDisposable $ pure ()
  mconcat disposables = mkDisposable $ traverse_ dispose disposables


mkDisposable :: AsyncIO () -> Disposable
mkDisposable = Disposable

synchronousDisposable :: IO () -> Disposable
synchronousDisposable = mkDisposable . liftIO

noDisposable :: Disposable
noDisposable = mempty
