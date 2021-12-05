{-# LANGUAGE CApiFFI #-}

module Quasar.Timer.PosixTimer (
  CTimeSpec,
  CITimerSpec,
  boottime,
) where

import Control.Concurrent
import Foreign
import Foreign.C
import Quasar.Disposable
import Quasar.Prelude
import System.Posix.Types

#include <signal.h>
#include <time.h>

foreign import capi "signal.h value SIGEV_THREAD"
  c_SIGEV_THREAD :: CInt

data CSigEvent = CSigEventThreadCallback (FunPtr SigevNotifyFunction)

instance Storable CSigEvent where
  sizeOf _ = #size struct sigevent
  alignment _ = #alignment struct sigevent
  peek _ = fail "Cannot peek SigEvent"
  poke ptr (CSigEventThreadCallback funPtr) = do
    #{poke struct sigevent, sigev_notify} ptr c_SIGEV_THREAD
    #{poke struct sigevent, sigev_notify_function} ptr funPtr


foreign import ccall "wrapper"
  mkSigevNotifyFunction :: SigevNotifyFunction -> IO (FunPtr SigevNotifyFunction)

type SigevNotifyFunction = (Ptr Void -> IO ())



data {-# CTYPE "struct timespec" #-} CTimeSpec = CTimeSpec {
  tv_sec :: CTime,
  tv_nsec :: CLong
}

instance Storable CTimeSpec where
  sizeOf _ = #size struct timespec
  alignment _ = #alignment struct timespec
  peek ptr = do
    tv_sec <- #{peek struct timespec, tv_sec} ptr
    tv_nsec <- #{peek struct timespec, tv_nsec} ptr
    pure CTimeSpec {
      tv_sec,
      tv_nsec
    }
  poke ptr CTimeSpec{tv_sec, tv_nsec} = do
    #{poke struct timespec, tv_sec} ptr tv_sec
    #{poke struct timespec, tv_nsec} ptr tv_nsec

defaultCTimeSpec :: CTimeSpec
defaultCTimeSpec = CTimeSpec 0 0

data {-# CTYPE "struct itimerspec" #-} CITimerSpec = CITimerSpec {
  it_interval :: CTimeSpec,
  it_value :: CTimeSpec
}

instance Storable CITimerSpec where
  sizeOf _ = #size struct itimerspec
  alignment _ = #alignment struct itimerspec
  peek ptr = do
    it_interval <- #{peek struct itimerspec, it_interval} ptr
    it_value <- #{peek struct itimerspec, it_value} ptr
    pure CITimerSpec {
      it_interval,
      it_value
    }
  poke ptr CITimerSpec{it_interval, it_value} = do
    #{poke struct itimerspec, it_interval} ptr it_interval
    #{poke struct itimerspec, it_value} ptr it_value

defaultCITimerSpec :: CITimerSpec
defaultCITimerSpec = CITimerSpec defaultCTimeSpec defaultCTimeSpec

foreign import capi "time.h value CLOCK_BOOTTIME"
  c_CLOCK_BOOTTIME :: CClockId


foreign import capi "time.h timer_create"
  c_timer_create :: CClockId -> Ptr CSigEvent -> Ptr CTimer -> IO CInt

foreign import capi "time.h timer_settime"
  c_timer_settime :: CTimer -> CInt -> Ptr CITimerSpec -> Ptr CITimerSpec -> IO CInt

foreign import capi "time.h timer_delete"
  c_timer_delete :: CTimer -> IO CInt


data PosixTimer = PosixTimer {
  ctimer :: CTimer,
  callbackPtr :: (FunPtr SigevNotifyFunction)
}

instance IsDisposable PosixTimer where
  toDisposable = undefined


newUnmanagedPosixTimer :: CClockId -> IO () -> IO PosixTimer
newUnmanagedPosixTimer clockId callback = runInBoundThread do
  callbackPtr <- mkSigevNotifyFunction (const callback)

  ctimer <- alloca \ctimerPtr -> do
    alloca \sigevent -> do
      poke sigevent $ CSigEventThreadCallback callbackPtr
      throwErrnoIfMinus1_ "timer_create" do
        c_timer_create c_CLOCK_BOOTTIME sigevent ctimerPtr
      peek ctimerPtr

  pure $ PosixTimer { ctimer, callbackPtr }

setPosixTimer :: PosixTimer -> Maybe CTimeSpec -> IO ()
setPosixTimer PosixTimer{ctimer} timeSpec = do
  alloca \newValue -> do
    poke newValue $ defaultCITimerSpec {
      it_value = fromMaybe defaultCTimeSpec timeSpec
    }
    throwErrnoIfMinus1_ "timer_settime" do
      c_timer_settime ctimer 0 newValue nullPtr

setPosixIntervalTimer :: PosixTimer -> CITimerSpec -> IO ()
setPosixIntervalTimer PosixTimer{ctimer}  iTimerSpec = do
  alloca \newValue -> do
    poke newValue iTimerSpec
    throwErrnoIfMinus1_ "timer_settime" do
      c_timer_settime ctimer 0 newValue nullPtr




boottime :: IO ()
boottime = runInBoundThread do

  callbackPtr <- mkSigevNotifyFunction callback

  ctimer <- alloca \ctimerPtr -> do
    alloca \sigevent -> do
      poke sigevent $ CSigEventThreadCallback callbackPtr
      throwErrnoIfMinus1_ "timer_create" do
        c_timer_create c_CLOCK_BOOTTIME sigevent ctimerPtr
      peek ctimerPtr

  alloca \newValue -> do
    poke newValue oneSecond
    throwErrnoIfMinus1_ "timer_settime" do
      c_timer_settime ctimer 0 newValue nullPtr
  where
    oneSecond = defaultCITimerSpec {
      it_value = defaultCTimeSpec {
        tv_sec = 1
      }
    }
    callback :: Ptr Void -> IO ()
    callback _ = traceIO "callback"
