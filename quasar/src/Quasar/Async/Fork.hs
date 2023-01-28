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
  forkAsyncSTM,
  forkAsyncWithUnmaskSTM,
) where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Exception.Ex
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


-- * Fork in STM (with ExceptionSink)

forkSTM :: IO () -> TIOWorker -> ExceptionSink -> STM (FutureEx '[AsyncException] ThreadId)
forkSTM fn = forkWithUnmaskSTM (\unmask -> unmask fn)

forkSTM_ :: IO () -> TIOWorker -> ExceptionSink -> STM ()
forkSTM_ fn worker exChan = void $ forkSTM fn worker exChan


forkWithUnmaskSTM :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionSink -> STM (FutureEx '[AsyncException] ThreadId)
-- TODO change TIOWorker behavior for spawning threads, so no `unsafeShortIO` is necessary
forkWithUnmaskSTM fn worker exChan = startShortIOSTM (unsafeShortIO $ forkWithUnmask fn exChan) worker exChan

forkWithUnmaskSTM_ :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionSink -> STM ()
forkWithUnmaskSTM_ fn worker exChan = void $ forkWithUnmaskSTM fn worker exChan


forkAsyncSTM :: forall a. IO a -> TIOWorker -> ExceptionSink -> STM (FutureEx '[AsyncException] a)
-- TODO change TIOWorker behavior for spawning threads, so no `unsafeShortIO` is necessary
forkAsyncSTM fn worker exChan = join <$> startShortIOSTM (unsafeShortIO $ forkFuture fn exChan) worker exChan

forkAsyncWithUnmaskSTM :: forall a. ((forall b. IO b -> IO b) -> IO a) -> TIOWorker -> ExceptionSink -> STM (FutureEx '[AsyncException] a)
-- TODO change TIOWorker behavior for spawning threads, so no `unsafeShortIO` is necessary
forkAsyncWithUnmaskSTM fn worker exChan = join <$> startShortIOSTM (unsafeShortIO $ forkFutureWithUnmask fn exChan) worker exChan


-- * Fork in IO, redirecting errors to an ExceptionSink

fork :: IO () -> ExceptionSink -> IO ThreadId
fork fn exSink = forkWithUnmask (\unmask -> unmask fn) exSink

fork_ :: IO () -> ExceptionSink -> IO ()
fork_ fn exSink = void $ fork fn exSink

forkWithUnmask :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> IO ThreadId
forkWithUnmask fn exChan = mask_ $ forkIOWithUnmask wrappedFn
  where
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionSink exChan ex)

forkWithUnmask_ :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> IO ()
forkWithUnmask_ fn exChan = void $ forkWithUnmask fn exChan


-- * Fork in IO while collecting the result, redirecting errors to an ExceptionSink

forkFuture :: forall a. IO a -> ExceptionSink -> IO (FutureEx '[AsyncException] a)
forkFuture fn = forkFutureWithUnmask (\unmask -> unmask fn)

forkFutureWithUnmask :: forall a. ((forall b. IO b -> IO b) -> IO a) -> ExceptionSink -> IO (FutureEx '[AsyncException] a)
forkFutureWithUnmask fn exChan = do
  resultVar <- newPromiseIO
  forkWithUnmask_ (runAndPut resultVar) exChan
  pure $ toFutureEx resultVar
  where
    runAndPut :: PromiseEx '[AsyncException] a -> (forall b. IO b -> IO b) -> IO ()
    runAndPut resultVar unmask = do
      -- Called in masked state by `forkWithUnmaskShortIO`
      result <- try $ fn unmask
      case result of
        Left ex ->
          atomically (throwToExceptionSink exChan ex)
            `finally`
              fulfillPromiseIO resultVar (Left (toEx (AsyncException ex)))
        Right retVal -> do
          fulfillPromiseIO resultVar (Right retVal)
