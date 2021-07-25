module Quasar.Core (
  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  awaitResult,

  -- * Cancellation
  withCancellationToken,
) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM
import Control.Exception (MaskingState(..), getMaskingState)
import Control.Monad.Catch
import Data.Maybe (isJust)
import Data.Void (absurd)
import Quasar.Awaitable
import Quasar.Prelude


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




-- * Awaiting multiple asyncs

awaitEither :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> AsyncIO (Either ra rb)
awaitEither x y = AsyncIOPlumbing $ \_ _ -> AsyncIOAsync <$> awaitEitherPlumbing x y

awaitEitherPlumbing :: (IsAwaitable ra a , IsAwaitable rb b) => a -> b -> IO (Awaitable (Either ra rb))
awaitEitherPlumbing x y = awaitableFromSTM $ peekEitherSTM x y

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
