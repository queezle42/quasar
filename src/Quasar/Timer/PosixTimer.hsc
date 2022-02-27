{-# LANGUAGE CApiFFI #-}

module Quasar.Timer.PosixTimer (
  ClockId(..),
  toCClockId,
  TimerSetTimeMode(..),
  CTimeSpec(..),
  defaultCTimeSpec,
  CITimerSpec(..),
  defaultCITimerSpec,
  newPosixTimer,
  setPosixTimer,
  setPosixIntervalTimer,
) where

import Control.Concurrent
import Control.Monad.Catch (MonadMask)
import Control.Monad.STM (atomically)
import Foreign
import Foreign.C
import Quasar.Prelude
import Quasar.MonadQuasar
import Quasar.Resources
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


data ClockId
  = Realtime
  | Monotonic
  | ProcessCputime
  | ThreadCputime
  | Boottime
  | RealtimeAlarm
  | BoottimeAlarm
  | Tai

toCClockId :: ClockId -> CClockId
toCClockId Realtime = c_CLOCK_REALTIME
toCClockId Monotonic = c_CLOCK_MONOTONIC
toCClockId ProcessCputime = c_CLOCK_PROCESS_CPUTIME_ID
toCClockId ThreadCputime = c_CLOCK_THREAD_CPUTIME_ID
toCClockId Boottime = c_CLOCK_BOOTTIME
toCClockId RealtimeAlarm = c_CLOCK_REALTIME_ALARM
toCClockId BoottimeAlarm = c_CLOCK_BOOTTIME_ALARM
toCClockId Tai = c_CLOCK_TAI

foreign import capi "time.h value CLOCK_REALTIME"
  c_CLOCK_REALTIME :: CClockId

foreign import capi "time.h value CLOCK_MONOTONIC"
  c_CLOCK_MONOTONIC :: CClockId

foreign import capi "time.h value CLOCK_PROCESS_CPUTIME_ID"
  c_CLOCK_PROCESS_CPUTIME_ID :: CClockId

foreign import capi "time.h value CLOCK_THREAD_CPUTIME_ID"
  c_CLOCK_THREAD_CPUTIME_ID :: CClockId

foreign import capi "time.h value CLOCK_BOOTTIME"
  c_CLOCK_BOOTTIME :: CClockId

foreign import capi "time.h value CLOCK_REALTIME_ALARM"
  c_CLOCK_REALTIME_ALARM :: CClockId

foreign import capi "time.h value CLOCK_BOOTTIME_ALARM"
  c_CLOCK_BOOTTIME_ALARM :: CClockId

foreign import capi "time.h value CLOCK_TAI"
  c_CLOCK_TAI :: CClockId



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


foreign import capi "time.h timer_create"
  c_timer_create :: CClockId -> Ptr CSigEvent -> Ptr CTimer -> IO CInt

foreign import capi "time.h timer_settime"
  c_timer_settime :: CTimer -> CInt -> Ptr CITimerSpec -> Ptr CITimerSpec -> IO CInt

foreign import capi "time.h timer_delete"
  c_timer_delete :: CTimer -> IO CInt

foreign import capi "time.h value TIMER_ABSTIME"
  c_TIMER_ABSTIME :: CInt

data TimerSetTimeMode = TimeRelative | TimeAbsolute

toCSetTimeFlags :: TimerSetTimeMode -> CInt
toCSetTimeFlags TimeRelative = 0
toCSetTimeFlags TimeAbsolute = c_TIMER_ABSTIME


data PosixTimer = PosixTimer {
  ctimer :: CTimer,
  disposer :: Disposer
}

instance Resource PosixTimer where
  getDisposer = disposer


newPosixTimer :: (MonadQuasar m, MonadIO m) => ClockId -> IO () -> m PosixTimer
newPosixTimer clockId callback = do
  (callbackPtr, ctimer) <- liftIO $ runInBoundThread do
    callbackPtr <- mkSigevNotifyFunction (const callback)

    ctimer <- alloca \ctimerPtr -> do
      alloca \sigevent -> do
        poke sigevent $ CSigEventThreadCallback callbackPtr
        throwErrnoIfMinus1_ "timer_create" do
          c_timer_create (toCClockId clockId) sigevent ctimerPtr
        peek ctimerPtr

    pure (callbackPtr, ctimer)

  disposer <- registerDisposeAction (delete ctimer callbackPtr)

  pure $ PosixTimer { ctimer, disposer }
  where
    delete :: CTimer -> FunPtr SigevNotifyFunction -> IO ()
    delete ctimer callbackPtr = do
      c_timer_delete ctimer
      -- "The treatment of any pending signal generated by the deleted timer is unspecified."
      freeHaskellFunPtr callbackPtr


setPosixTimer :: PosixTimer -> TimerSetTimeMode -> CTimeSpec -> IO ()
setPosixTimer timer mode timeSpec = setPosixIntervalTimer timer mode itspec
  where
    itspec = defaultCITimerSpec {
      it_value = timeSpec
    }

setPosixIntervalTimer :: PosixTimer -> TimerSetTimeMode -> CITimerSpec -> IO ()
setPosixIntervalTimer PosixTimer{ctimer} mode iTimerSpec = do
  alloca \newValue -> do
    poke newValue iTimerSpec
    throwErrnoIfMinus1_ "timer_settime" do
      c_timer_settime ctimer (toCSetTimeFlags mode) newValue nullPtr

disarmPosixTimer :: PosixTimer -> IO ()
disarmPosixTimer timer = setPosixIntervalTimer timer TimeRelative defaultCITimerSpec
