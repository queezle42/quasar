module Quasar.Core (
  -- * Awaitable
  IsAwaitable(..),
  awaitSTM,
  Awaitable,
  successfulAwaitable,
  failedAwaitable,
  completedAwaitable,
  peekAwaitable,

  -- * AsyncVar
  AsyncVar,
  newAsyncVar,
  putAsyncVar,

  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  awaitResult,

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
import Control.Concurrent.STM
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.Maybe (isJust)
import Data.Void (absurd)
import Quasar.Prelude

-- * Awaitable

class IsAwaitable r a | a -> r where
  peekSTM :: a -> STM (Maybe (Either SomeException r))
  peekSTM = peekSTM . toAwaitable

  toAwaitable :: a -> Awaitable r
  toAwaitable = SomeAwaitable

  {-# MINIMAL toAwaitable | peekSTM #-}


-- | Wait until the promise is settled and return the result.
awaitSTM :: IsAwaitable r a => a -> STM (Either SomeException r)
awaitSTM = peekSTM >=> maybe retry pure


data Awaitable r = forall a. IsAwaitable r a => SomeAwaitable a

instance IsAwaitable r (Awaitable r) where
  peekSTM (SomeAwaitable x) = peekSTM x
  toAwaitable = id

instance Functor Awaitable where
  fmap fn = toAwaitable . FnAwaitable . fmap (fmap (fmap fn)) . peekSTM



newtype CompletedAwaitable r = CompletedAwaitable (Either SomeException r)
instance IsAwaitable r (CompletedAwaitable r) where
  peekSTM (CompletedAwaitable value) = pure $ Just value

completedAwaitable :: Either SomeException r -> Awaitable r
completedAwaitable = toAwaitable . CompletedAwaitable

successfulAwaitable :: r -> Awaitable r
successfulAwaitable = completedAwaitable . Right

failedAwaitable :: SomeException -> Awaitable r
failedAwaitable = completedAwaitable . Left


peekAwaitable :: (IsAwaitable r a, MonadIO m) => a -> m (Maybe (Either SomeException r))
peekAwaitable = liftIO . atomically . peekSTM


newtype FnAwaitable r = FnAwaitable (STM (Maybe (Either SomeException r)))
instance IsAwaitable r (FnAwaitable r) where
  peekSTM (FnAwaitable fn) = fn

awaitableSTM :: STM (Maybe (Either SomeException r)) -> IO (Awaitable r)
awaitableSTM fn = do
  cache <- newTVarIO (Left fn)
  pure . toAwaitable . FnAwaitable $
    readTVar cache >>= \case
      Left generatorFn -> do
        value <- generatorFn
        writeTVar cache (Right value)
        pure value
      Right value -> pure value


-- * AsyncIO

data AsyncIO r
  = AsyncIOSuccess r
  | AsyncIOFailure SomeException
  | AsyncIOIO (IO r)
  | AsyncIOAsync (Awaitable r)
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

bindAsync :: forall a b. Awaitable a -> (a -> AsyncIO b) -> AsyncIO b
bindAsync x fn = bindAsyncCatch x (either AsyncIOFailure fn)

bindAsyncCatch :: forall a b. Awaitable a -> (Either SomeException a -> AsyncIO b) -> AsyncIO b
bindAsyncCatch x fn = undefined -- AsyncIOPlumbing $ \maskingState cancellationToken -> do
  --var <- newAsyncVar
  --disposableMVar <- newEmptyMVar
  --go maskingState cancellationToken var disposableMVar
  --where
  --  go maskingState cancellationToken var disposableMVar = do
  --    disposable <- onResult x (failAsyncVar_ var) $ \x -> do
  --      (putAsyncIOResult . fn) x
  --    -- TODO update mvar and dispose when completed
  --    putMVar disposableMVar disposable
  --    pure $ awaitUnlessCancellationRequested cancellationToken var
  --    where
  --      put = putAsyncVarEither var
  --      putAsyncIOResult :: AsyncIO b -> IO ()
  --      putAsyncIOResult (AsyncIOSuccess x) = put (Right x)
  --      putAsyncIOResult (AsyncIOFailure x) = put (Left x)
  --      putAsyncIOResult (AsyncIOIO x) = try x >>= put
  --      putAsyncIOResult (AsyncIOAsync x) = onResult_ x (put . Left) put
  --      putAsyncIOResult (AsyncIOPlumbing x) = x maskingState cancellationToken >>= putAsyncIOResult



-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Awaitable r)
async (AsyncIOSuccess x) = pure $ successfulAwaitable x
async (AsyncIOFailure x) = pure $ failedAwaitable x
async (AsyncIOIO x) = liftIO $ either failedAwaitable successfulAwaitable <$> try x
async (AsyncIOAsync x) = pure x -- TODO caching
async (AsyncIOPlumbing x) = mapPlumbing x (fmap async)

await :: IsAwaitable r a => a -> AsyncIO r
await = AsyncIOAsync . toAwaitable

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO (AsyncIOSuccess x) = pure x
runAsyncIO (AsyncIOFailure x) = throwIO x
runAsyncIO (AsyncIOIO x) = x
runAsyncIO (AsyncIOAsync x) = either throwIO pure =<< atomically (awaitSTM x)
runAsyncIO (AsyncIOPlumbing x) = do
  maskingState <- getMaskingState
  withCancellationToken $ x maskingState >=> runAsyncIO

awaitResult :: AsyncIO (Awaitable r) -> AsyncIO r
awaitResult = (await =<<)



-- ** Forking asyncs

-- TODO
--class IsAsyncForkable m where
--  asyncThread :: m r -> AsyncIO r


-- * Async helpers

-- ** AsyncVar

-- | The default implementation for an `Awaitable` that can be fulfilled later.
newtype AsyncVar r = AsyncVar (TMVar (Either SomeException r))

instance IsAwaitable r (AsyncVar r) where
  peekSTM (AsyncVar var) = tryReadTMVar var

tryPutAsyncVarEitherSTM :: AsyncVar a -> Either SomeException a -> STM Bool
tryPutAsyncVarEitherSTM (AsyncVar var) = tryPutTMVar var

tryPutAsyncVarEither :: forall a m. MonadIO m => AsyncVar a -> Either SomeException a -> m Bool
tryPutAsyncVarEither var = liftIO . atomically . tryPutAsyncVarEitherSTM var


newAsyncVarSTM :: STM (AsyncVar r)
newAsyncVarSTM = AsyncVar <$> newEmptyTMVar

newAsyncVar :: MonadIO m => m (AsyncVar r)
newAsyncVar = liftIO $ AsyncVar <$> newEmptyTMVarIO


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

awaitEither :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> AsyncIO (Either ra rb)
awaitEither x y = AsyncIOPlumbing $ \_ _ -> AsyncIOAsync <$> awaitEitherPlumbing x y

awaitEitherPlumbing :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> IO (Awaitable (Either ra rb))
awaitEitherPlumbing x y = awaitableSTM $ peekEitherSTM x y

peekEitherSTM :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> STM (Maybe (Either SomeException (Either ra rb)))
peekEitherSTM x y =
  peekSTM x >>= \case
    Just (Left ex) -> pure (Just (Left ex))
    Just (Right r) -> pure (Just (Right (Left r)))
    Nothing -> peekSTM y >>= \case
      Just (Left ex) -> pure (Just (Left ex))
      Just (Right r) -> pure (Just (Right (Right r)))
      Nothing -> pure Nothing


-- * Cancellation

newtype CancellationToken = CancellationToken (AsyncVar Void)

instance IsAwaitable Void CancellationToken where
  toAwaitable (CancellationToken var) = toAwaitable var

newCancellationToken :: IO CancellationToken
newCancellationToken = CancellationToken <$> newAsyncVar

cancel :: Exception e => CancellationToken -> e -> IO ()
cancel (CancellationToken var) = failAsyncVar_ var . toException

isCancellationRequested :: CancellationToken -> IO Bool
isCancellationRequested (CancellationToken var) = isJust <$> peekAwaitable var

cancellationState :: CancellationToken -> IO (Maybe SomeException)
cancellationState (CancellationToken var) = (either Just (const Nothing) =<<) <$> peekAwaitable var

throwIfCancellationRequested :: CancellationToken -> IO ()
throwIfCancellationRequested (CancellationToken var) =
  peekAwaitable var >>= \case
    Just (Left ex) -> throwIO ex
    _ -> pure ()

awaitUnlessCancellationRequested :: IsAwaitable a b => CancellationToken -> b -> AsyncIO a
awaitUnlessCancellationRequested cancellationToken = fmap (either absurd id) . awaitEither cancellationToken . toAwaitable


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
