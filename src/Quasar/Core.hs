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
  Disposable,
  mkDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.HashMap.Strict qualified as HM
import Data.Maybe (isJust)
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait x = do
    mvar <- newEmptyMVar
    onResult_ x (void . tryPutMVar mvar . Left) (resultCallback mvar)
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
    -> (SomeException -> IO ())
    -- ^ callback exception handler
    -> (Either SomeException r -> IO ())
    -- ^ callback
    -> IO Disposable

  onResult_
    :: a
    -> (SomeException -> IO ())
    -> (Either SomeException r -> IO ())
    -> IO ()
  onResult_ x y = void . onResult x y

  toAsync :: a -> Async r
  toAsync = SomeAsync


data Async r = forall a. IsAsync r a => SomeAsync a

instance IsAsync r (Async r) where
  wait (SomeAsync x) = wait x
  onResult (SomeAsync x) y = onResult x y
  onResult_ (SomeAsync x) y = onResult_ x y
  peekAsync (SomeAsync x) = peekAsync x



newtype CompletedAsync r = CompletedAsync (Either SomeException r)
instance IsAsync r (CompletedAsync r) where
  wait (CompletedAsync value) = either throwIO pure value
  onResult (CompletedAsync value) callbackExceptionHandler callback = noDisposable <$ (callback value `catch` callbackExceptionHandler)
  peekAsync (CompletedAsync value) = pure $ Just value

completedAsync :: Either SomeException r -> Async r
completedAsync = toAsync . CompletedAsync

successfulAsync :: r -> Async r
successfulAsync = completedAsync . Right

failedAsync :: SomeException -> Async r
failedAsync = completedAsync . Left


-- * AsyncIO

data AsyncIO r
  = AsyncIOSuccess r
  | AsyncIOFailure SomeException
  | AsyncIOIO (IO r)
  | AsyncIOAsync (Async r)
  | AsyncIOPlumbing (IO (AsyncIO r))

instance Functor AsyncIO where
  fmap fn = (>>= pure . fn)

instance Applicative AsyncIO where
  pure = AsyncIOSuccess
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py

instance Monad AsyncIO where
  (>>=) :: forall a b. AsyncIO a -> (a -> AsyncIO b) -> AsyncIO b
  (>>=) (AsyncIOSuccess x) fn = fn x
  (>>=) (AsyncIOFailure x) _ = AsyncIOFailure x
  (>>=) (AsyncIOIO x) fn = AsyncIOPlumbing $ either AsyncIOFailure fn <$> try x
  (>>=) (AsyncIOAsync x) fn = bindAsync x fn
  (>>=) (AsyncIOPlumbing x) fn = AsyncIOPlumbing $ (>>= fn) <$> x

instance MonadIO AsyncIO where
  liftIO = AsyncIOIO

instance MonadThrow AsyncIO where
  throwM = AsyncIOFailure . toException

instance MonadCatch AsyncIO where
  catch :: Exception e => AsyncIO a -> (e -> AsyncIO a) -> AsyncIO a
  catch x@(AsyncIOSuccess _) _ = x
  catch x@(AsyncIOFailure ex) handler = maybe x handler (fromException ex)
  catch (AsyncIOIO x) handler = AsyncIOIO (try x) >>= handleEither handler
  catch (AsyncIOAsync x) handler = bindAsyncCatch x (handleEither handler)
  catch (AsyncIOPlumbing x) handler = AsyncIOPlumbing $ (`catch` handler) <$> x

handleEither :: Exception e => (e -> AsyncIO a) -> Either SomeException a -> AsyncIO a
handleEither handler (Left ex) = maybe (AsyncIOFailure ex) handler (fromException ex)
handleEither _ (Right r) = pure r

bindAsync :: forall a b. Async a -> (a -> AsyncIO b) -> AsyncIO b
bindAsync x fn = bindAsyncCatch x (either AsyncIOFailure fn)

bindAsyncCatch :: forall a b. Async a -> (Either SomeException a -> AsyncIO b) -> AsyncIO b
bindAsyncCatch x fn = AsyncIOPlumbing $ newAsyncVar >>= bindAsync'
  where
    bindAsync' resultVar = do
      withResult x resultVar step
      pure $ await resultVar
    step :: (Either SomeException b -> IO ()) -> Either SomeException a -> IO ()
    step put = putAsyncIOResult put . fn

withResult :: Async a -> AsyncVar b -> ((Either SomeException b -> IO ()) -> Either SomeException a -> IO ()) -> IO ()
withResult x var fn = onResult_ x (failAsyncVar var) (fn (putAsyncVarEither var))

putAsyncIOResult :: (Either SomeException a -> IO ()) -> AsyncIO a -> IO ()
putAsyncIOResult put (AsyncIOSuccess x) = put (Right x)
putAsyncIOResult put (AsyncIOFailure x) = put (Left x)
putAsyncIOResult put (AsyncIOIO x) = try x >>= put
putAsyncIOResult put (AsyncIOAsync x) = onResult_ x (put . Left) put
putAsyncIOResult put (AsyncIOPlumbing x) = x >>= putAsyncIOResult put



-- | Run the synchronous part of an `AsyncIO` and then return an `Async` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Async r)
async = fmap successfulAsync

await :: IsAsync r a => a -> AsyncIO r
await = AsyncIOAsync . toAsync

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO (AsyncIOSuccess x) = pure x
runAsyncIO (AsyncIOFailure x) = throwIO x
runAsyncIO (AsyncIOIO x) = x
runAsyncIO (AsyncIOAsync x) = wait x
runAsyncIO (AsyncIOPlumbing x) = do
  x >>= runAsyncIO

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
data AsyncVarState r
  = AsyncVarCompleted (Either SomeException r)
  | AsyncVarOpen (HM.HashMap Unique (Either SomeException r -> IO (), SomeException -> IO ()))

instance IsAsync r (AsyncVar r) where
  peekAsync :: AsyncVar r -> IO (Maybe (Either SomeException r))
  peekAsync (AsyncVar mvar) = readMVar mvar >>= pure . \case
    AsyncVarCompleted x -> Just x
    AsyncVarOpen _ -> Nothing

  onResult :: AsyncVar r -> (SomeException -> IO ()) -> (Either SomeException r -> IO ()) -> IO Disposable
  onResult (AsyncVar mvar) callbackExceptionHandler callback =
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
putAsyncVar var = putAsyncVarEither var . Right

failAsyncVar :: MonadIO m => AsyncVar a -> SomeException -> m ()
failAsyncVar var = putAsyncVarEither var . Left

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


-- * Cancellation

newtype CancellationToken = CancellationToken (AsyncVar Void)

newCancellationToken :: IO CancellationToken
newCancellationToken = CancellationToken <$> newAsyncVar

cancel :: Exception e => CancellationToken -> e -> IO ()
cancel (CancellationToken var) = failAsyncVar var . toException

isCancellationRequested :: CancellationToken -> IO Bool
isCancellationRequested (CancellationToken var) = isJust <$> peekAsync var

cancellationState :: CancellationToken -> IO (Maybe SomeException)
cancellationState (CancellationToken var) = (either Just (const Nothing) =<<) <$> peekAsync var

throwIfCancellationRequested :: CancellationToken -> IO ()
throwIfCancellationRequested (CancellationToken var) =
  peekAsync var >>= \case
    Just (Left ex) -> throwIO ex
    _ -> pure ()

withCancellationToken :: (CancellationToken -> IO a) -> IO a
withCancellationToken action = do
  cancellationToken <- newCancellationToken
  resultMVar :: MVar (Either SomeException a) <- newEmptyMVar

  uninterruptibleMask $ \unmask -> do
    void $ forkIOWithUnmask $ \threadUnmask -> do
      putMVar resultMVar =<< try (threadUnmask (action cancellationToken))

    either throwIO pure =<< (unmask (takeMVar resultMVar) `catchAll` (\ex -> cancel cancellationToken ex >> takeMVar resultMVar))


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
