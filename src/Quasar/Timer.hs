{-# LANGUAGE MultiWayIf #-}

module Quasar.Timer (
  Timer,
  newTimer,
  sleepUntil,

  TimerScheduler,
  newTimerScheduler,

  TimerCancelled,

  Delay,
  newDelay,
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Catch
import Data.Heap
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Foldable (toList)
import Quasar.Async
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude


data TimerCancelled = TimerCancelled
  deriving stock (Eq, Show)

instance Exception TimerCancelled


data Timer = Timer {
  key :: Unique,
  time :: UTCTime,
  completed :: AsyncVar (),
  scheduler :: TimerScheduler
}

instance Eq Timer where
  x == y = key x == key y

instance Ord Timer where
  x `compare` y = time x `compare` time y

instance IsDisposable Timer where
  dispose self = do
    atomically do
      cancelled <- failAsyncVarSTM (completed self) TimerCancelled
      when cancelled do
        modifyTVar (activeCount (scheduler self)) (+ (-1))
        modifyTVar (cancelledCount (scheduler self)) (+ 1)
    pure $ isDisposed self

  isDisposed = awaitSuccessOrFailure . completed

instance IsAwaitable () Timer where
  toAwaitable = toAwaitable . completed


data TimerScheduler = TimerScheduler {
  heap :: TVar (Heap Timer),
  activeCount :: TVar Int,
  cancelledCount :: TVar Int,
  resourceManager :: ResourceManager
}

instance IsDisposable TimerScheduler where
  toDisposable = toDisposable . resourceManager

data TimerSchedulerDisposed = TimerSchedulerDisposed
  deriving stock (Eq, Show)

instance Exception TimerSchedulerDisposed

newTimerScheduler :: ResourceManager -> IO TimerScheduler
newTimerScheduler parentResourceManager = do
  heap <- newTVarIO empty
  activeCount <- newTVarIO 0
  cancelledCount <- newTVarIO 0
  resourceManager <- newResourceManager parentResourceManager
  let scheduler = TimerScheduler {
          heap,
          activeCount,
          cancelledCount,
          resourceManager
        }
  startSchedulerThread scheduler
  pure scheduler

startSchedulerThread :: TimerScheduler -> IO ()
startSchedulerThread scheduler = do
  mask_ do
    threadId <- forkIOWithUnmask ($ schedulerThread)
    attachDisposeAction_ (resourceManager scheduler) do
      throwTo threadId TimerSchedulerDisposed
      pure $ pure ()
  where
    resourceManager' :: ResourceManager
    resourceManager' = resourceManager scheduler
    heap' :: TVar (Heap Timer)
    heap' = heap scheduler
    activeCount' = activeCount scheduler
    cancelledCount' = cancelledCount scheduler

    schedulerThread :: IO ()
    schedulerThread = forever do

      -- Get next timer (blocks when heap is empty)
      nextTimer <- atomically do
        uncons <$> readTVar heap' >>= \case
          Nothing -> retry
          Just (timer, _) -> pure timer

      now <- getCurrentTime

      -- TODO sleep using Posix/Linux create_timer using CLOCK_REALTIME
      let timeUntil = diffUTCTime (time nextTimer) now
      if
        | timeUntil <= 0 -> fireTimers now
        | timeUntil < 60 -> wait nextTimer (ceiling $ toRational timeUntil * 1000000)
        | otherwise -> wait nextTimer (60 * 1000000)

    wait :: Timer -> Int -> IO ()
    wait nextTimer microseconds = do
      delay <- toAwaitable <$> newDelay resourceManager' microseconds
      awaitAny2 delay nextTimerChanged
      where
        nextTimerChanged :: Awaitable ()
        nextTimerChanged = unsafeAwaitSTM do
          minTimer <- Data.Heap.minimum <$> readTVar heap'
          unless (minTimer /= nextTimer) retry

    fireTimers :: UTCTime -> IO ()
    fireTimers now = atomically do
      writeTVar heap' =<< go =<< readTVar heap'
      doCleanup <- liftA2 (>) (readTVar cancelledCount') (readTVar activeCount')
      when doCleanup cleanup
      where
        go :: Heap Timer -> STM (Heap Timer)
        go timers = do
          case uncons timers of
            Nothing -> pure timers
            Just (timer, others) -> do
              if (time timer) <= now
                then do
                  result <- putAsyncVarSTM (completed timer) ()
                  modifyTVar (if result then activeCount' else cancelledCount') (+ (-1))
                  pure others
                 else pure timers

    cleanup :: STM ()
    cleanup = writeTVar heap' . fromList =<< mapMaybeM cleanupTimer =<< (toList <$> readTVar heap')

    cleanupTimer :: Timer -> STM (Maybe Timer)
    cleanupTimer timer = do
      cancelled <- ((False <$ readAsyncVarSTM (completed timer)) `catch` \TimerCancelled -> pure True) `orElse` pure False
      if cancelled
        then do
          modifyTVar cancelledCount' (+ (-1))
          pure Nothing
        else pure $ Just timer



newTimer :: TimerScheduler -> UTCTime -> IO Timer
newTimer scheduler time = do
  key <- newUnique
  completed <- newAsyncVar
  let timer = Timer { key, time, completed, scheduler }
  atomically do
    modifyTVar (heap scheduler) (insert timer)
    modifyTVar (activeCount scheduler) (+ 1)
  pure timer


sleepUntil :: TimerScheduler -> UTCTime -> IO ()
sleepUntil scheduler time = bracketOnError (newTimer scheduler time) disposeAndAwait await



-- | Can be awaited successfully after a given number of microseconds. Based on `threadDelay`, but provides an
-- `IsAwaitable` and `IsDisposable` instance.
newtype Delay = Delay (Task ())
  deriving newtype IsDisposable

instance IsAwaitable () Delay where
  toAwaitable (Delay task) = toAwaitable task `catch` \TaskDisposed -> throwM TimerCancelled

newDelay :: ResourceManager -> Int -> IO Delay
newDelay resourceManager microseconds = onResourceManager resourceManager $ Delay <$> async (liftIO (threadDelay microseconds))



-- From package `extra`
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM op = foldr f (pure [])
    where f x xs = do y <- op x; case y of Nothing -> xs; Just z -> do ys <- xs; pure $ z:ys
