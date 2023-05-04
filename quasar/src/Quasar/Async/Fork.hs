module Quasar.Async.Fork (
  -- * Forking with an asynchronous exception channel

  -- ** IO
  fork,
  fork_,
  forkWithUnmask,
  forkWithUnmask_,
  forkFuture,
  forkFutureWithUnmask,

  -- ** STM
  forkSTM,
  forkSTM_,
  forkWithUnmaskSTM,
  forkWithUnmaskSTM_,
  forkFutureSTM,
  forkFutureWithUnmaskSTM,
  forkOnRetry,
) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask)
import Control.Exception.Ex
import Control.Monad.Catch
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import System.IO.Unsafe (unsafePerformIO)


data Job = Job ((forall a. IO a -> IO a) -> IO ()) (Maybe (Promise ThreadId))

forkJobQueue :: TQueue Job
forkJobQueue = unsafePerformIO do
  queue <- newTQueueIO
  void $ forkIO $ mask_ $ forever do
    items <- atomically do
      items <- flushTQueue queue
      check (not (null items))
      pure items
    forM_ items \(Job job mpromise) -> do
      tid <- forkIOWithUnmask job
      forM_ mpromise \promise ->
        tryFulfillPromiseIO_ promise tid
  pure queue
{-# NOINLINE forkJobQueue #-}

queueForkIOWithUnmaskSTM :: MonadSTMc NoRetry '[] m => ((forall a. IO a -> IO a) -> IO ()) -> m (Future ThreadId)
queueForkIOWithUnmaskSTM job = do
  promise <- newPromise
  writeTQueue forkJobQueue $ Job job (Just promise)
  pure (toFuture promise)

queueForkIOWithUnmaskSTM_ :: MonadSTMc NoRetry '[] m => ((forall a. IO a -> IO a) -> IO ()) -> m ()
queueForkIOWithUnmaskSTM_ job = do
  writeTQueue forkJobQueue $ Job job Nothing


-- * Fork in STM (with ExceptionSink)

forkSTM ::
  MonadSTMc NoRetry '[] m =>
  IO () -> ExceptionSink -> m (Future ThreadId)
forkSTM fn = forkWithUnmaskSTM (\unmask -> unmask fn)

forkSTM_ :: MonadSTMc NoRetry '[] m => IO () -> ExceptionSink -> m ()
forkSTM_ fn = forkWithUnmaskSTM_ (\unmask -> unmask fn)


forkWithUnmaskSTM ::
  MonadSTMc NoRetry '[] m =>
  ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> m (Future ThreadId)
forkWithUnmaskSTM fn sink = queueForkIOWithUnmaskSTM (wrapWithExceptionSink fn sink)

forkWithUnmaskSTM_ ::
  MonadSTMc NoRetry '[] m =>
  ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> m ()
forkWithUnmaskSTM_ fn sink = queueForkIOWithUnmaskSTM_ (wrapWithExceptionSink fn sink)


forkFutureSTM ::
  MonadSTMc NoRetry '[] m =>
  IO a -> ExceptionSink -> m (FutureEx '[AsyncException] a)
forkFutureSTM fn = forkFutureWithUnmaskSTM (\unmask -> unmask fn)

forkFutureWithUnmaskSTM ::
  MonadSTMc NoRetry '[] m =>
  ((forall b. IO b -> IO b) -> IO a) ->
  ExceptionSink ->
  m (FutureEx '[AsyncException] a)
forkFutureWithUnmaskSTM fn sink = do
  resultVar <- newPromise
  forkWithUnmaskSTM_ (runAndPut fn sink resultVar) sink
  pure $ toFutureEx resultVar


forkOnRetry :: forall m a. MonadSTMc NoRetry '[] m => STM a -> ExceptionSink -> m (FutureEx '[AsyncException] a)
forkOnRetry f sink = liftSTMc $ fx `orElseC` fy
  where
    fx :: STMc Retry '[] (FutureEx '[AsyncException] a)
    fx =
      catchAllSTMc @Retry @'[SomeException]
        (pure <$> liftSTM f)
        \ex -> do
          throwToExceptionSink sink ex
          pure (throwC (AsyncException ex))
    fy :: STMc NoRetry '[] (FutureEx '[AsyncException] a)
    fy = forkFutureSTM (atomically f) sink


-- * Fork in IO, redirecting errors to an ExceptionSink

fork :: IO () -> ExceptionSink -> IO ThreadId
fork fn exSink = forkWithUnmask (\unmask -> unmask fn) exSink

fork_ :: IO () -> ExceptionSink -> IO ()
fork_ fn exSink = void $ fork fn exSink

forkWithUnmask :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> IO ThreadId
forkWithUnmask fn sink = mask_ $ forkIOWithUnmask (wrapWithExceptionSink fn sink)

forkWithUnmask_ :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> IO ()
forkWithUnmask_ fn sink = void $ forkWithUnmask fn sink


-- * Fork in IO while collecting the result, redirecting errors to an ExceptionSink

forkFuture :: forall a. IO a -> ExceptionSink -> IO (FutureEx '[AsyncException] a)
forkFuture fn = forkFutureWithUnmask (\unmask -> unmask fn)

forkFutureWithUnmask :: forall a. ((forall b. IO b -> IO b) -> IO a) -> ExceptionSink -> IO (FutureEx '[AsyncException] a)
forkFutureWithUnmask fn sink = do
  resultVar <- newPromiseIO
  forkWithUnmask_ (runAndPut fn sink resultVar) sink
  pure $ toFutureEx resultVar

-- * Implementation helpers

runAndPut ::
  forall a. ((forall b. IO b -> IO b) -> IO a) ->
  ExceptionSink ->
  PromiseEx '[AsyncException] a ->
  (forall b. IO b -> IO b) ->
  IO ()
runAndPut fn sink resultVar unmask = do
  -- Called in masked state by `forkWithUnmask_`
  result <- try $ fn unmask
  case result of
    Left ex ->
      atomically (throwToExceptionSink sink ex)
        `finally`
          fulfillPromiseIO resultVar (Left (toEx (AsyncException ex)))
    Right retVal -> do
      fulfillPromiseIO resultVar (Right retVal)

wrapWithExceptionSink ::
  ((forall a. IO a -> IO a) -> IO ()) ->
  ExceptionSink ->
  (forall a. IO a -> IO a) ->
  IO ()
wrapWithExceptionSink fn sink unmask =
  fn unmask `catchAll` \ex -> atomically (throwToExceptionSink sink ex)
