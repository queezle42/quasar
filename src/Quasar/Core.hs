module Quasar.Core (
  -- * AsyncIO
  AsyncIO,
  async,
  await,
  askPool,
  runAsyncIO,
  awaitResult,
) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, myThreadId)
import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashSet
import Data.Sequence
import Quasar.Awaitable
import Quasar.Prelude


-- * AsyncIO


newtype AsyncT m a = AsyncT (ReaderT Pool m a)
  deriving newtype (MonadTrans, Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask)

type AsyncIO = AsyncT IO


-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Awaitable r)
async action = asyncWithUnmask (\unmask -> unmask action)

-- | Run the synchronous part of an `AsyncIO` and then return an `Awaitable` that can be used to wait for completion of the synchronous part.
asyncWithUnmask :: ((forall a. AsyncIO a -> AsyncIO a) -> AsyncIO r) -> AsyncIO (Awaitable r)
-- TODO resource limits
asyncWithUnmask action = mask_ $ do
  pool <- askPool
  resultVar <- newAsyncVar
  liftIO $ forkIOWithUnmask $ \unmask -> do
    result <- try $ runOnPool pool (action (liftUnmask unmask))
    putAsyncVarEither_ resultVar result
  pure $ toAwaitable resultVar

liftUnmask :: (IO a -> IO a) -> AsyncIO a -> AsyncIO a
liftUnmask unmask action = do
  pool <- askPool
  liftIO $ unmask $ runOnPool pool action

askPool :: AsyncIO Pool
askPool = AsyncT ask

await :: IsAwaitable r a => a -> AsyncIO r
-- TODO resource limits
await = liftIO . awaitIO

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO = withDefaultPool




awaitResult :: AsyncIO (Awaitable r) -> AsyncIO r
awaitResult = (await =<<)

-- TODO rename to ResourceManager
data Pool = Pool {
  configuration :: PoolConfiguraiton,
  threads :: TVar (HashSet ThreadId)
}

newtype AsyncTask r = AsyncTask (Awaitable r)
instance IsAwaitable r (AsyncTask r) where
  toAwaitable (AsyncTask awaitable) = awaitable

data CancelTask = CancelTask
  deriving stock Show
instance Exception CancelTask where

data CancelledTask = CancelledTask
  deriving stock Show
instance Exception CancelledTask where


data PoolConfiguraiton = PoolConfiguraiton

defaultPoolConfiguration :: PoolConfiguraiton
defaultPoolConfiguration = PoolConfiguraiton

withPool :: PoolConfiguraiton -> AsyncIO r -> IO r
withPool configuration = bracket (newPool configuration) disposePool . flip runOnPool

runOnPool :: Pool -> AsyncIO r -> IO r
runOnPool pool (AsyncT action) = runReaderT action pool


withDefaultPool :: AsyncIO a -> IO a
withDefaultPool = withPool defaultPoolConfiguration

newPool :: PoolConfiguraiton -> IO Pool
newPool configuration = do
  threads <- newTVarIO mempty
  pure Pool {
    configuration,
    threads
  }

disposePool :: Pool -> IO ()
-- TODO resource management
disposePool = const (pure ())
