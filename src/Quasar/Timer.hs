{-# LANGUAGE MultiWayIf #-}

module Quasar.Timer (
  Timer,
  newTimer,
  newUnmanagedTimer,
  sleepUntil,

  TimerScheduler,
  newTimerScheduler,
  newUnmanagedTimerScheduler,

  TimerCancelled,

  Delay,
  newDelay,
  newUnmanagedDelay,
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad.Catch
import Data.Heap
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Foldable (toList)
import Quasar.Async
import Quasar.Async.Unmanaged
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude
import Quasar.ResourceManager


data TimerCancelled = TimerCancelled
  deriving stock (Eq, Show)

instance Exception TimerCancelled


data Timer = Timer {
  key :: Unique,
  time :: UTCTime,
  completed :: AsyncVar (),
  disposable :: STMDisposable,
  scheduler :: TimerScheduler
}

instance Eq Timer where
  x == y = key x == key y

instance Ord Timer where
  x `compare` y = time x `compare` time y

instance IsDisposable Timer where
  toDisposable Timer{disposable} = toDisposable disposable

instance IsAwaitable () Timer where
  toAwaitable Timer{completed} = toAwaitable completed


data TimerScheduler = TimerScheduler {
  heap :: TMVar (Heap Timer),
  activeCount :: TVar Int,
  cancelledCount :: TVar Int,
  disposable :: Disposable
}

instance IsDisposable TimerScheduler where
  toDisposable TimerScheduler{disposable} = disposable

data TimerSchedulerDisposed = TimerSchedulerDisposed
  deriving stock (Eq, Show)

instance Exception TimerSchedulerDisposed

newTimerScheduler :: MonadResourceManager m => m TimerScheduler
newTimerScheduler = registerNewResource newUnmanagedTimerScheduler

newUnmanagedTimerScheduler :: MonadIO m => m TimerScheduler
newUnmanagedTimerScheduler = do
  liftIO do
    heap <- newTMVarIO empty
    activeCount <- newTVarIO 0
    cancelledCount <- newTVarIO 0
    mfix \scheduler -> do
      disposable <- startSchedulerThread scheduler
      pure TimerScheduler {
        heap,
        activeCount,
        cancelledCount,
        disposable
      }

startSchedulerThread :: TimerScheduler -> IO Disposable
startSchedulerThread scheduler = toDisposable <$> unmanagedAsync (schedulerThread `finally` cancelAll)
  where
    heap' :: TMVar (Heap Timer)
    heap' = heap scheduler
    activeCount' = activeCount scheduler
    cancelledCount' = cancelledCount scheduler

    schedulerThread :: IO ()
    schedulerThread = forever do

      -- Get next timer (blocks when heap is empty)
      nextTimer <- atomically do
        uncons <$> readTMVar heap' >>= \case
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
      delay <- newUnmanagedDelay microseconds
      awaitAny2 (await delay) nextTimerChanged
      dispose delay
      where
        nextTimerChanged :: Awaitable ()
        nextTimerChanged = unsafeAwaitSTM do
          minTimer <- Data.Heap.minimum <$> readTMVar heap'
          unless (minTimer /= nextTimer) retry

    fireTimers :: UTCTime -> IO ()
    fireTimers now = atomically do
      putTMVar heap' =<< go =<< takeTMVar heap'
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
                  fireTimer timer
                  pure others
                 else pure timers

    fireTimer :: Timer -> STM ()
    fireTimer Timer{completed, disposable} = do
      result <- putAsyncVarSTM completed ()
      modifyTVar (if result then activeCount' else cancelledCount') (+ (-1))
      disposeSTMDisposable disposable

    cleanup :: STM ()
    cleanup = putTMVar heap' . fromList =<< mapMaybeM cleanupTimer =<< (toList <$> takeTMVar heap')

    cleanupTimer :: Timer -> STM (Maybe Timer)
    cleanupTimer timer = do
      cancelled <- ((False <$ readAsyncVarSTM (completed timer)) `catch` \TimerCancelled -> pure True) `orElse` pure False
      if cancelled
        then do
          modifyTVar cancelledCount' (+ (-1))
          pure Nothing
        else pure $ Just timer

    cancelAll :: IO ()
    cancelAll = do
      timers <- atomically $ takeTMVar heap'
      mapM_ dispose timers


newTimer :: MonadResourceManager m => TimerScheduler -> UTCTime -> m Timer
newTimer scheduler time =
  registerNewResource $ newUnmanagedTimer scheduler time


newUnmanagedTimer :: MonadIO m => TimerScheduler -> UTCTime -> m Timer
newUnmanagedTimer scheduler time = liftIO do
  key <- newUnique
  completed <- newAsyncVar
  atomically do
    disposable <- newSTMDisposable' do
      cancelled <- failAsyncVarSTM completed TimerCancelled
      when cancelled do
        modifyTVar (activeCount scheduler) (+ (-1))
        modifyTVar (cancelledCount scheduler) (+ 1)
    let timer = Timer { key, time, completed, disposable, scheduler }
    tryTakeTMVar (heap scheduler) >>= \case
      Just timers -> putTMVar (heap scheduler) (insert timer timers)
      Nothing -> throwM TimerSchedulerDisposed
    modifyTVar (activeCount scheduler) (+ 1)
    pure timer


sleepUntil :: MonadIO m => TimerScheduler -> UTCTime -> m ()
sleepUntil scheduler time = liftIO $ bracketOnError (newUnmanagedTimer scheduler time) dispose await



-- | Provides an `IsAwaitable` instance that can be awaited successfully after a given number of microseconds.
--
-- Based on `threadDelay`. Provides a `IsAwaitable` and a `IsDisposable` instance.
newtype Delay = Delay (Async ())
  deriving newtype IsDisposable

instance IsAwaitable () Delay where
  toAwaitable (Delay task) = toAwaitable task `catch` \AsyncDisposed -> throwM TimerCancelled

newDelay :: MonadResourceManager m => Int -> m Delay
newDelay microseconds = registerNewResource $ newUnmanagedDelay microseconds

newUnmanagedDelay :: MonadIO m => Int -> m Delay
newUnmanagedDelay microseconds = Delay <$> unmanagedAsync (liftIO (threadDelay microseconds))



-- From package `extra`
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM op = foldr f (pure [])
    where f x xs = do y <- op x; case y of Nothing -> xs; Just z -> do ys <- xs; pure $ z:ys
