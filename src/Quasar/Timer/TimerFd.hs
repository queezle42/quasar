{-# LANGUAGE CApiFFI #-}

module Quasar.Timer.TimerFd (
  TimerFd,
  newTimerFd,
  setTimer,
  setInterval,
  disarm,
) where

import Control.Concurrent
import Control.Monad.Catch
import Foreign
import Foreign.C
import GHC.Conc (closeFdWith)
import GHC.IO.Handle.FD
import Quasar.Awaitable
import Quasar.Async
import Quasar.Disposable
import Quasar.Prelude
import Quasar.ResourceManager
import Quasar.Timer.PosixTimer
import System.IO
import System.Posix.Types


foreign import capi "sys/timerfd.h timerfd_create"
  c_timerfd_create :: CClockId -> CInt -> IO TimerFd

foreign import capi "sys/timerfd.h timerfd_settime"
  c_timerfd_settime :: TimerFd -> CInt -> Ptr CITimerSpec -> Ptr CITimerSpec -> IO CInt

foreign import capi "unistd.h read"
  c_timerfd_read :: TimerFd -> Ptr Word64 -> CSize -> IO CInt

foreign import capi "unistd.h close"
  c_timerfd_close :: TimerFd -> IO CInt

foreign import capi "sys/timerfd.h value TFD_CLOEXEC"
  c_TFD_CLOEXEC :: CInt

newtype TimerFd = TimerFd Fd
  deriving stock (Eq, Show)
  deriving newtype Num

newTimerFd :: (MonadResourceManager m, MonadIO m, MonadMask m) => ClockId -> IO () -> m TimerFd
newTimerFd clockId callback = mask_ do
  timer <- liftIO $ runInBoundThread do
    throwErrnoIfMinus1 "timerfd_create" do
      c_timerfd_create (toCClockId clockId) c_TFD_CLOEXEC

  workerTask <- async $ liftIO $ worker timer
  registerAsyncDisposeAction do
    await $ isDisposed workerTask
    timerFdClose timer

  pure timer

  where
    worker :: TimerFd -> IO ()
    worker timer@(TimerFd fd) = forever do
      -- Block until timer is expired using the GHC runtime.
      -- The thread will be unblocked with an `AsyncCancelled`-Exception, so
      -- (contrary to the documentation) `closeFdWith` should not be necessary
      -- when closing the fd.
      threadWaitRead fd
      elapsed <- timerFdRead timer
      traceShowIO elapsed
      callback


setTimer :: TimerFd -> TimerSetTimeMode -> CTimeSpec -> IO ()
setTimer timer mode timeSpec = setInterval timer mode itspec
  where
    itspec = defaultCITimerSpec {
      it_value = timeSpec
    }

setInterval :: TimerFd -> TimerSetTimeMode -> CITimerSpec -> IO ()
setInterval timer mode iTimerSpec = do
  alloca \newValue -> do
    poke newValue iTimerSpec
    throwErrnoIfMinus1_ "timer_settime" do
      c_timerfd_settime timer 0 newValue nullPtr

disarm :: TimerFd -> IO ()
disarm timer = setInterval timer TimeRelative defaultCITimerSpec


timerFdRead :: TimerFd -> IO Word64
timerFdRead timer = do
  alloca \ptr -> do
    throwErrnoIfMinus1 "timerfd_read" do
      c_timerfd_read timer ptr 8
    peek ptr

timerFdClose :: TimerFd -> IO ()
timerFdClose timer = throwErrnoIfMinus1_ "timerfd_close" $ c_timerfd_close timer
