module Quasar.Async.Fork (
  -- * Forking with an asynchronous exception channel
  -- ** STM
  fork,
  fork_,
  forkWithUnmask,
  forkWithUnmask_,

  -- ** ShortIO
  forkWithUnmaskShortIO,
  forkWithUnmaskShortIO_,
  startIOThreadShortIO,
  startIOThreadWithUnmaskShortIO,
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

fork :: IO () -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
fork fn = forkWithUnmask (\unmask -> unmask fn)

fork_ :: IO () -> TIOWorker -> ExceptionChannel -> STM ()
fork_ fn worker exChan = void $ fork fn worker exChan


forkWithUnmask :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM (Awaitable ThreadId)
forkWithUnmask fn worker exChan = startShortIO (forkWithUnmaskShortIO fn exChan) worker exChan

forkWithUnmask_ :: ((forall a. IO a -> IO a) -> IO ()) -> TIOWorker -> ExceptionChannel -> STM ()
forkWithUnmask_ fn worker exChan = void $ forkWithUnmask fn worker exChan


-- * Fork in ShortIO (with ExceptionChannel)

forkWithUnmaskShortIO :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionChannel -> ShortIO ThreadId
forkWithUnmaskShortIO fn exChan = forkFn
  where
    forkFn :: ShortIO ThreadId
    forkFn = mask_ $ forkIOWithUnmaskShortIO wrappedFn
    wrappedFn :: (forall a. IO a -> IO a) -> IO ()
    wrappedFn unmask = fn unmask `catchAll` \ex -> atomically (throwToExceptionChannel exChan ex)

forkWithUnmaskShortIO_ :: ((forall a. IO a -> IO a) -> IO ()) -> ExceptionChannel -> ShortIO ()
forkWithUnmaskShortIO_ fn exChan = void $ forkWithUnmaskShortIO fn exChan


-- * Fork in ShortIO while collecting the result (with ExceptionChannel)

startIOThreadWithUnmaskShortIO :: forall a. ((forall b. IO b -> IO b) -> IO a) -> ExceptionChannel -> ShortIO (Awaitable a)
startIOThreadWithUnmaskShortIO fn exChan = do
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


startIOThreadShortIO :: forall a. IO a -> ExceptionChannel -> ShortIO (Awaitable a)
startIOThreadShortIO fn = startIOThreadWithUnmaskShortIO ($ fn)
