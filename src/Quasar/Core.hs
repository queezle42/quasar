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
  awaitResult,

  -- * Async helpers
  mapAsync,

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

import Control.Monad.Catch
import Data.HashMap.Strict qualified as HM
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait x = do
    mvar <- newEmptyMVar
    onResult_ (void . tryPutMVar mvar . Left) x (resultCallback mvar)
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
    :: (SomeException -> IO ())
    -- ^ callback exception handler
    -> a
    -- ^ async
    -> (Either SomeException r -> IO ())
    -- ^ callback
    -> IO Disposable

  onResult_
    :: (SomeException -> IO ())
    -> a
    -> (Either SomeException r -> IO ())
    -> IO ()
  onResult_ x y = void . onResult x y

  toAsync :: a -> Async r
  toAsync = SomeAsync


data Async r = forall a. IsAsync r a => SomeAsync a

instance IsAsync r (Async r) where
  wait (SomeAsync x) = wait x
  onResult y (SomeAsync x) = onResult y x
  onResult_ y (SomeAsync x) = onResult_ y x
  peekAsync (SomeAsync x) = peekAsync x
  toAsync = id


newtype CompletedAsync r = CompletedAsync (Either SomeException r)
instance IsAsync r (CompletedAsync r) where
  wait (CompletedAsync value) = either throwIO pure value
  onResult callbackExceptionHandler (CompletedAsync value) callback = noDisposable <$ (callback value `catch` callbackExceptionHandler)
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
  (>>=) :: forall a b. AsyncIO a -> (a -> AsyncIO b) -> AsyncIO b
  lhs >>= fn = AsyncIO $ newAsyncVar >>= go
    where
      go resultVar = do
        lhsAsync <- async lhs
        lhsAsync `onResultBound` \case
          Right lhsResult ->  do
            rhsAsync <- async $ fn lhsResult
            rhsAsync `onResultBound` putAsyncVarEither resultVar
          Left lhsEx -> putAsyncVarEither resultVar (Left lhsEx)
        pure $ toAsync resultVar
        where
          onResultBound :: forall r. Async r -> (Either SomeException r -> IO ()) -> IO ()
          onResultBound = onResult_ (putAsyncVarEither resultVar . Left)

instance MonadIO AsyncIO where
  liftIO = AsyncIO . fmap successfulAsync


-- | Run the synchronous part of an `AsyncIO` and then return an `Async` that can be used to wait for completion of the synchronous part.
async :: MonadIO m => AsyncIO r -> m (Async r)
async (AsyncIO x) = liftIO x

await :: IsAsync r a => a -> AsyncIO r
await = AsyncIO . pure . toAsync

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO = async >=> wait

awaitResult :: AsyncIO (Async r) -> AsyncIO r
awaitResult = (await =<<)


mapAsync :: (a -> b) -> Async a -> AsyncIO (Async b)
-- FIXME: don't actually attach a function if the resulting async is not used
-- maybe use `Weak`? When `Async b` is GC'ed, the handler is detached from `Async a`
mapAsync fn = async . fmap fn . await



-- ** Forking asyncs

-- TODO
--class IsAsyncForkable m where
--  asyncThread :: m r -> AsyncIO r


-- * Async helpers

-- ** AsyncVar

-- | The default implementation for a `Async` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (MVar (AsyncVarState r))
data AsyncVarState r = AsyncVarCompleted (Either SomeException r) | AsyncVarOpen (HM.HashMap Unique (Either SomeException r -> IO (), SomeException -> IO ()))

instance IsAsync r (AsyncVar r) where
  peekAsync :: AsyncVar r -> IO (Maybe (Either SomeException r))
  peekAsync (AsyncVar mvar) = readMVar mvar >>= pure . \case
    AsyncVarCompleted x -> Just x
    AsyncVarOpen _ -> Nothing

  onResult :: (SomeException -> IO ()) -> AsyncVar r -> (Either SomeException r -> IO ()) -> IO Disposable
  onResult callbackExceptionHandler (AsyncVar mvar) callback =
    modifyMVar mvar $ \case
      AsyncVarOpen callbacks -> do
        key <- newUnique
        pure (AsyncVarOpen (HM.insert key (callback, callbackExceptionHandler) callbacks), removeHandler key)
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
  mask $ \restore -> do
    takeMVar mvar >>= \case
      x@(AsyncVarCompleted _) -> do
        putMVar mvar x
        fail "An AsyncVar can only be fulfilled once"
      AsyncVarOpen callbacksMap -> do
        let callbacks = HM.elems callbacksMap
        -- NOTE disposing a callback while it is called is a deadlock
        forM_ callbacks $ \(callback, callbackExceptionHandler) ->
          restore (callback value) `catch` callbackExceptionHandler
        putMVar mvar (AsyncVarCompleted value)


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
disposeEventually = void . async . dispose

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
