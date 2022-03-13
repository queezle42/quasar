module Quasar.Async.Fork (
  -- * Forking with an asynchronous exception channel
  -- ** STM
  forkSTM,
  forkSTM_,
  forkWithUnmaskSTM,
  forkWithUnmaskSTM_,
  forkAsyncSTM,
  forkAsyncWithUnmaskSTM,

  -- ** ShortIO
  forkWithUnmaskShortIO,
  forkWithUnmaskShortIO_,
  forkAsyncShortIO,
  forkAsyncWithUnmaskShortIO,
) where

import Control.Concurrent (ThreadId)
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Future
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


-- * Fork in STM (with ExceptionSink)

forkSTM :: IO () -> TIOWorker -> ExceptionSink -> STM (Future ThreadId)
forkSTM fn = forkWithUnmaskSTM (\unmask -> unmask fn)

forkSTM_ :: IO () -> TIOWorker -> ExceptionSink -> STM ()
forkSTM_ fn worker exChan = void $ forkSTM fn worker exChan


forkWithUnmaskSTM :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionSink -> STM (Future ThreadId)
forkWithUnmaskSTM fn worker exChan = startShortIOSTM (forkWithUnmaskShortIO fn exChan) worker exChan

forkWithUnmaskSTM_ :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionSink -> STM ()
forkWithUnmaskSTM_ fn worker exChan = void $ forkWithUnmaskSTM fn worker exChan


forkAsyncSTM :: forall a. IO a -> TIOWorker -> ExceptionSink -> STM (Future a)
forkAsyncSTM fn worker exChan = join <$> startShortIOSTM (forkAsyncShortIO fn exChan) worker exChan

forkAsyncWithUnmaskSTM :: forall a. ((forall b. IO b -> IO b) -> IO a) -> TIOWorker -> ExceptionSink -> STM (Future a)
forkAsyncWithUnmaskSTM fn worker exChan = join <$> startShortIOSTM (forkAsyncWithUnmaskShortIO fn exChan) worker exChan


-- * Fork in ShortIO (with ExceptionSink)

forkWithUnmaskShortIO :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> ShortIO ThreadId
forkWithUnmaskShortIO fn exChan = mask_ $ forkIOWithUnmaskShortIO wrappedFn
  where
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionSink exChan ex)

forkWithUnmaskShortIO_ :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionSink -> ShortIO ()
forkWithUnmaskShortIO_ fn exChan = void $ forkWithUnmaskShortIO fn exChan


-- * Fork in ShortIO while collecting the result (with ExceptionSink)

forkAsyncShortIO :: forall a. IO a -> ExceptionSink -> ShortIO (Future a)
forkAsyncShortIO fn = forkAsyncWithUnmaskShortIO ($ fn)

forkAsyncWithUnmaskShortIO :: forall a. ((forall b. IO b -> IO b) -> IO a) -> ExceptionSink -> ShortIO (Future a)
forkAsyncWithUnmaskShortIO fn exChan = do
  resultVar <- newPromiseShortIO
  forkWithUnmaskShortIO_ (runAndPut resultVar) exChan
  pure $ toFuture resultVar
  where
    runAndPut :: Promise a -> (forall b. IO b -> IO b) -> IO ()
    runAndPut resultVar unmask = do
      -- Called in masked state by `forkWithUnmaskShortIO`
      result <- try $ fn unmask
      case result of
        Left ex ->
          atomically (throwToExceptionSink exChan ex)
            `finally`
              breakPromise resultVar (AsyncException ex)
        Right retVal -> do
          fulfillPromise resultVar retVal
