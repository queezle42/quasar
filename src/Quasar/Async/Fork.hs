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
import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Prelude
import Quasar.Utils.ShortIO


-- * Fork in STM (with ExceptionChannel)

forkSTM :: IO () -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
forkSTM fn = forkWithUnmaskSTM (\unmask -> unmask fn)

forkSTM_ :: IO () -> TIOWorker -> ExceptionChannel -> STM ()
forkSTM_ fn worker exChan = void $ forkSTM fn worker exChan


forkWithUnmaskSTM :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
forkWithUnmaskSTM fn worker exChan = startShortIOSTM (forkWithUnmaskShortIO fn exChan) worker exChan

forkWithUnmaskSTM_ :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM ()
forkWithUnmaskSTM_ fn worker exChan = void $ forkWithUnmaskSTM fn worker exChan


forkAsyncSTM :: forall a. IO a -> TIOWorker -> ExceptionChannel -> STM (Awaitable a)
forkAsyncSTM fn worker exChan = join <$> startShortIOSTM (forkAsyncShortIO fn exChan) worker exChan

forkAsyncWithUnmaskSTM :: forall a. ((forall b. IO b -> IO b) -> IO a) -> TIOWorker -> ExceptionChannel -> STM (Awaitable a)
forkAsyncWithUnmaskSTM fn worker exChan = join <$> startShortIOSTM (forkAsyncWithUnmaskShortIO fn exChan) worker exChan


-- * Fork in ShortIO (with ExceptionChannel)

forkWithUnmaskShortIO :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionChannel -> ShortIO ThreadId
forkWithUnmaskShortIO fn exChan = mask_ $ forkIOWithUnmaskShortIO wrappedFn
  where
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionChannel exChan ex)

forkWithUnmaskShortIO_ :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionChannel -> ShortIO ()
forkWithUnmaskShortIO_ fn exChan = void $ forkWithUnmaskShortIO fn exChan


-- * Fork in ShortIO while collecting the result (with ExceptionChannel)

forkAsyncShortIO :: forall a. IO a -> ExceptionChannel -> ShortIO (Awaitable a)
forkAsyncShortIO fn = forkAsyncWithUnmaskShortIO ($ fn)

forkAsyncWithUnmaskShortIO :: forall a. ((forall b. IO b -> IO b) -> IO a) -> ExceptionChannel -> ShortIO (Awaitable a)
forkAsyncWithUnmaskShortIO fn exChan = do
  resultVar <- newAsyncVarShortIO
  forkWithUnmaskShortIO_ (runAndPut resultVar) exChan
  pure $ toAwaitable resultVar
  where
    runAndPut :: AsyncVar a -> (forall b. IO b -> IO b) -> IO ()
    runAndPut resultVar unmask = do
      -- Called in masked state by `forkWithUnmaskShortIO`
      result <- try $ fn unmask
      case result of
        Left ex ->
          atomically (throwToExceptionChannel exChan ex)
            `finally`
              failAsyncVar_ resultVar (AsyncException ex)
        Right retVal -> do
          putAsyncVar_ resultVar retVal
