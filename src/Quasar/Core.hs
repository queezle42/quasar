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
  Disposable,
  mkDisposable,
  synchronousDisposable,
  noDisposable,

  -- * Cancellation
  withCancellationToken,
) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.HashMap.Strict qualified as HM
import Data.Maybe (isJust)
import Data.Void (absurd)
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait = wait . toAsync

  peekAsync :: a -> IO (Maybe (Either SomeException r))
  peekAsync = peekAsync . toAsync

  -- | Register a callback, that will be called once the promise is settled.
  -- If the promise is already settled, the callback will be called immediately instead.
  --
  -- The returned `Disposable` can be used to deregister the callback.
  --
  -- 'onResult' should not throw.
  onResult
    :: a
    -- ^ async
    -> (SomeException -> IO ())
    -- ^ callback exception handler
    -> (Either SomeException r -> IO ())
    -- ^ callback
    -> IO CallbackDisposable
  onResult x ceh c = onResult (toAsync x) ceh c

  onResult_
    :: a
    -> (SomeException -> IO ())
    -> (Either SomeException r -> IO ())
    -> IO ()
  onResult_ x ceh c = onResult_ (toAsync x) ceh c

  toAsync :: a -> Async r
  toAsync = SomeAsync

  {-# MINIMAL toAsync | (wait, peekAsync, onResult, onResult_) #-}


data Async r = forall a. IsAsync r a => SomeAsync a

instance IsAsync r (Async r) where
  wait (SomeAsync x) = wait x
  onResult (SomeAsync x) y = onResult x y
  onResult_ (SomeAsync x) y = onResult_ x y
  peekAsync (SomeAsync x) = peekAsync x

instance Functor Async where
  fmap fn = toAsync . MappedAsync fn



newtype CompletedAsync r = CompletedAsync (Either SomeException r)
instance IsAsync r (CompletedAsync r) where
  wait (CompletedAsync value) = either throwIO pure value
  onResult (CompletedAsync value) callbackExceptionHandler callback =
    noCallbackDisposable <$ (callback value `catch` callbackExceptionHandler)
  onResult_ (CompletedAsync value) callbackExceptionHandler callback =
    callback value `catch` callbackExceptionHandler
  peekAsync (CompletedAsync value) = pure $ Just value

completedAsync :: Either SomeException r -> Async r
completedAsync = toAsync . CompletedAsync

successfulAsync :: r -> Async r
successfulAsync = completedAsync . Right

failedAsync :: SomeException -> Async r
failedAsync = completedAsync . Left


data MappedAsync r = forall a. MappedAsync (a -> r) (Async a)
instance IsAsync r (MappedAsync r) where
  wait (MappedAsync fn x) = fn <$> wait x
  peekAsync (MappedAsync fn x) = fmap fn <<$>> peekAsync x
  onResult (MappedAsync fn x) callbackExceptionHandler callback = onResult x callbackExceptionHandler $ callback . fmap fn
  onResult_ (MappedAsync fn x) callbackExceptionHandler callback = onResult_ x callbackExceptionHandler $ callback . fmap fn


-- * AsyncIO

data AsyncIO r
  = AsyncIOSuccess r
  | AsyncIOFailure SomeException
  | AsyncIOIO (IO r)
  | AsyncIOAsync (Async r)
  | AsyncIOPlumbing (MaskingState -> CancellationToken -> IO (AsyncIO r))

instance Functor AsyncIO where
  fmap fn (AsyncIOSuccess x) = AsyncIOSuccess (fn x)
  fmap _ (AsyncIOFailure x) = AsyncIOFailure x
  fmap fn (AsyncIOIO x) = AsyncIOIO (fn <$> x)
  fmap fn (AsyncIOAsync x) = AsyncIOAsync (fn <$> x)
  fmap fn (AsyncIOPlumbing x) = mapPlumbing x (fmap (fmap fn))

instance Applicative AsyncIO where
  pure = AsyncIOSuccess
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py

instance Monad AsyncIO where
  (>>=) :: forall a b. AsyncIO a -> (a -> AsyncIO b) -> AsyncIO b
  (>>=) (AsyncIOSuccess x) fn = fn x
  (>>=) (AsyncIOFailure x) _ = AsyncIOFailure x
  (>>=) (AsyncIOIO x) fn = AsyncIOPlumbing $ \maskingState cancellationToken -> do
    -- TODO masking and cancellation
    either AsyncIOFailure fn <$> try x
  (>>=) (AsyncIOAsync x) fn = bindAsync x fn
  (>>=) (AsyncIOPlumbing x) fn = mapPlumbing x (fmap (>>= fn))

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
  catch (AsyncIOPlumbing x) handler = mapPlumbing x (fmap (`catch` handler))

handleEither :: Exception e => (e -> AsyncIO a) -> Either SomeException a -> AsyncIO a
handleEither handler (Left ex) = maybe (AsyncIOFailure ex) handler (fromException ex)
handleEither _ (Right r) = pure r

mapPlumbing :: (MaskingState -> CancellationToken -> IO (AsyncIO a)) -> (IO (AsyncIO a) -> IO (AsyncIO b)) -> AsyncIO b
mapPlumbing plumbing fn = AsyncIOPlumbing $ \maskingState cancellationToken -> fn (plumbing maskingState cancellationToken)

bindAsync :: forall a b. Async a -> (a -> AsyncIO b) -> AsyncIO b
bindAsync x fn = bindAsyncCatch x (either AsyncIOFailure fn)

bindAsyncCatch :: forall a b. Async a -> (Either SomeException a -> AsyncIO b) -> AsyncIO b
bindAsyncCatch x fn = AsyncIOPlumbing $ \maskingState cancellationToken -> do
  var <- newAsyncVar
  disposableMVar <- newEmptyMVar
  go maskingState cancellationToken var disposableMVar
  where
    go maskingState cancellationToken var disposableMVar = do
      disposable <- onResult x (failAsyncVar_ var) $ \x -> do
        (putAsyncIOResult . fn) x
      -- TODO update mvar and dispose when completed
      putMVar disposableMVar disposable
      pure $ awaitUnlessCancellationRequested cancellationToken var
      where
        put = putAsyncVarEither var
        putAsyncIOResult :: AsyncIO b -> IO ()
        putAsyncIOResult (AsyncIOSuccess x) = put (Right x)
        putAsyncIOResult (AsyncIOFailure x) = put (Left x)
        putAsyncIOResult (AsyncIOIO x) = try x >>= put
        putAsyncIOResult (AsyncIOAsync x) = onResult_ x (put . Left) put
        putAsyncIOResult (AsyncIOPlumbing x) = x maskingState cancellationToken >>= putAsyncIOResult



-- | Run the synchronous part of an `AsyncIO` and then return an `Async` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Async r)
async (AsyncIOSuccess x) = pure $ successfulAsync x
async (AsyncIOFailure x) = pure $ failedAsync x
async (AsyncIOIO x) = liftIO $ either failedAsync successfulAsync <$> try x
async (AsyncIOAsync x) = pure x -- TODO caching
async (AsyncIOPlumbing x) = mapPlumbing x (fmap async)

await :: IsAsync r a => a -> AsyncIO r
await = AsyncIOAsync . toAsync

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO (AsyncIOSuccess x) = pure x
runAsyncIO (AsyncIOFailure x) = throwIO x
runAsyncIO (AsyncIOIO x) = x
runAsyncIO (AsyncIOAsync x) = wait x
runAsyncIO (AsyncIOPlumbing x) = do
  maskingState <- getMaskingState
  withCancellationToken $ x maskingState >=> runAsyncIO

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
  = AsyncVarCompleted (Either SomeException r) (IO ())
  | AsyncVarOpen (HM.HashMap Unique (Either SomeException r -> IO (), SomeException -> IO ()))

instance IsAsync r (AsyncVar r) where
  wait x = do
    mvar <- newEmptyMVar
    onResult_ x (void . tryPutMVar mvar . Left) (resultCallback mvar)
    readMVar mvar >>= either throwIO pure
    where
      resultCallback :: MVar (Either SomeException r) -> Either SomeException r -> IO ()
      resultCallback mvar result = do
        success <- tryPutMVar mvar result
        unless success $ fail "Callback was called multiple times"

  peekAsync :: AsyncVar r -> IO (Maybe (Either SomeException r))
  peekAsync (AsyncVar mvar) = readMVar mvar >>= pure . \case
    AsyncVarCompleted x _ -> Just x
    AsyncVarOpen _ -> Nothing

  onResult :: AsyncVar r -> (SomeException -> IO ()) -> (Either SomeException r -> IO ()) -> IO CallbackDisposable
  onResult (AsyncVar mvar) callbackExceptionHandler callback =
    modifyMVar mvar $ \case
      AsyncVarOpen callbacks -> do
        key <- newUnique
        pure (AsyncVarOpen (HM.insert key (callback, callbackExceptionHandler) callbacks), callbackDisposable key)
      x@(AsyncVarCompleted value _) -> (x, noCallbackDisposable) <$ callback value `catch` callbackExceptionHandler
    where
      callbackDisposable :: Unique -> CallbackDisposable
      callbackDisposable key = CallbackDisposable removeHandler removeHandlerEventually
        where
          removeHandler = do
            waitForCallbacks <- modifyMVar mvar $ pure . \case
              x@(AsyncVarCompleted _ waitForCallbacks) -> (x, waitForCallbacks)
              AsyncVarOpen x -> (AsyncVarOpen (HM.delete key x), pure ())
            -- Dispose should only return after the callback can't be called any longer
            -- If the callbacks are already being dispatched, wait for them to complete to keep the guarantee
            waitForCallbacks

          removeHandlerEventually =
            modifyMVar_ mvar $ pure . \case
              x@(AsyncVarCompleted _ _) -> x
              AsyncVarOpen x -> AsyncVarOpen $ HM.delete key x

  onResult_ x y = void . onResult x y

tryPutAsyncVarEither :: forall a m. MonadIO m => AsyncVar a -> Either SomeException a -> m Bool
tryPutAsyncVarEither (AsyncVar mvar) value = liftIO $ do
  action <- modifyMVar mvar $ \case
    x@(AsyncVarCompleted _ waitForCallbacks) -> pure (x, False <$ waitForCallbacks)
    AsyncVarOpen callbacksMap -> do
      callbacksCompletedMVar <- newEmptyMVar
      let waitForCallbacks = readMVar callbacksCompletedMVar
          callbacks = HM.elems callbacksMap
      pure (AsyncVarCompleted value waitForCallbacks, fireCallbacks callbacks callbacksCompletedMVar)

  action

  where
    fireCallbacks :: [(Either SomeException a -> IO (), SomeException -> IO ())] -> MVar () -> IO Bool
    fireCallbacks callbacks callbacksCompletedMVar = do
      forM_ callbacks $ \(callback, callbackExceptionHandler) ->
        callback value `catch` callbackExceptionHandler
      putMVar callbacksCompletedMVar ()
      pure True


newAsyncVar :: MonadIO m => m (AsyncVar r)
newAsyncVar = liftIO $ AsyncVar <$> newMVar (AsyncVarOpen HM.empty)


putAsyncVar :: MonadIO m => AsyncVar a -> a -> m ()
putAsyncVar var = putAsyncVarEither var . Right

tryPutAsyncVar :: MonadIO m => AsyncVar a -> a -> m Bool
tryPutAsyncVar var = tryPutAsyncVarEither var . Right

tryPutAsyncVar_ :: MonadIO m => AsyncVar a -> a -> m ()
tryPutAsyncVar_ var = void . tryPutAsyncVar var

failAsyncVar :: MonadIO m => AsyncVar a -> SomeException -> m Bool
failAsyncVar var = tryPutAsyncVarEither var . Left

failAsyncVar_ :: MonadIO m => AsyncVar a -> SomeException -> m ()
failAsyncVar_ var = void . failAsyncVar var

putAsyncVarEither :: MonadIO m => AsyncVar a -> Either SomeException a -> m ()
putAsyncVarEither avar value = liftIO $ do
  success <- tryPutAsyncVarEither avar value
  unless success $ fail "An AsyncVar can only be fulfilled once"

tryPutAsyncVarEither_ :: MonadIO m => AsyncVar a -> Either SomeException a -> m ()
tryPutAsyncVarEither_ var = void . tryPutAsyncVarEither var


-- * Awaiting multiple asyncs

awaitEither :: (IsAsync ra a , IsAsync rb b) => a -> b -> AsyncIO (Either ra rb)
awaitEither x y = AsyncIOPlumbing $ \_ _ -> AsyncIOAsync <$> awaitEitherPlumbing x y

awaitEitherPlumbing :: (IsAsync ra a , IsAsync rb b) => a -> b -> IO (Async (Either ra rb))
awaitEitherPlumbing x y = do
  var <- newAsyncVar
  d1 <- onResult x (failAsyncVar_ var) (tryPutAsyncVarEither_ var . fmap Left)
  d2 <- onResult y (failAsyncVar_ var) (tryPutAsyncVarEither_ var . fmap Right)
  -- The resulting async is kept in memory by 'x' or 'y' until one of them completes.
  onResult_ var (const (pure ())) (const (disposeCallbackEventually d1 *> disposeCallbackEventually d2))
  pure $ toAsync var


-- * Cancellation

newtype CancellationToken = CancellationToken (AsyncVar Void)

instance IsAsync Void CancellationToken where
  toAsync (CancellationToken var) = toAsync var

newCancellationToken :: IO CancellationToken
newCancellationToken = CancellationToken <$> newAsyncVar

cancel :: Exception e => CancellationToken -> e -> IO ()
cancel (CancellationToken var) = failAsyncVar_ var . toException

isCancellationRequested :: CancellationToken -> IO Bool
isCancellationRequested (CancellationToken var) = isJust <$> peekAsync var

cancellationState :: CancellationToken -> IO (Maybe SomeException)
cancellationState (CancellationToken var) = (either Just (const Nothing) =<<) <$> peekAsync var

throwIfCancellationRequested :: CancellationToken -> IO ()
throwIfCancellationRequested (CancellationToken var) =
  peekAsync var >>= \case
    Just (Left ex) -> throwIO ex
    _ -> pure ()

awaitUnlessCancellationRequested :: IsAsync a b => CancellationToken -> b -> AsyncIO a
awaitUnlessCancellationRequested cancellationToken = fmap (either absurd id) . awaitEither cancellationToken . toAsync


withCancellationToken :: (CancellationToken -> IO a) -> IO a
withCancellationToken action = do
  cancellationToken <- newCancellationToken
  resultMVar :: MVar (Either SomeException a) <- newEmptyMVar

  uninterruptibleMask $ \unmask -> do
    void $ forkIOWithUnmask $ \threadUnmask -> do
      putMVar resultMVar =<< try (threadUnmask (action cancellationToken))

    -- TODO test if it is better to run readMVar recursively or to keep it uninterruptible
    either throwIO pure =<< (unmask (readMVar resultMVar) `catchAll` (\ex -> cancel cancellationToken ex >> readMVar resultMVar))


-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource.
  dispose :: a -> AsyncIO ()

  -- | Dispose a resource in the IO monad.
  disposeIO :: a -> IO ()

  toDisposable :: a -> Disposable
  toDisposable = mkDisposable . dispose

instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose
  disposeIO = mapM_ disposeIO


newtype Disposable = Disposable (AsyncIO ())

instance IsDisposable Disposable where
  dispose (Disposable fn) = fn
  disposeIO = runAsyncIO . dispose
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



data CallbackDisposable = CallbackDisposable (IO ()) (IO ())

instance IsDisposable CallbackDisposable where
  dispose = liftIO . disposeCallback
  disposeIO = disposeCallback
  toDisposable = Disposable . dispose

disposeCallback :: CallbackDisposable -> IO ()
disposeCallback (CallbackDisposable f _) = f

disposeCallbackEventually :: CallbackDisposable -> IO ()
disposeCallbackEventually (CallbackDisposable _ e) = e

noCallbackDisposable :: CallbackDisposable
noCallbackDisposable = CallbackDisposable mempty mempty
