{-# LANGUAGE MultiWayIf #-}

module Quasar.Timer (
  Timer,
  newTimer,
  newUnmanagedTimer,
  sleepUntil,

  TimerScheduler,
  newTimerScheduler,

  TimerCancelled,

  Delay,
  newDelay,
) where

import Control.Concurrent
import Control.Monad.Catch
import Data.Bifunctor qualified as Bifunctor
import Data.Foldable (toList)
import Data.Heap
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Quasar.Async
import Quasar.Async.STMHelper
import Quasar.Exceptions
import Quasar.Future
import Quasar.MonadQuasar
import Quasar.Prelude
import Quasar.Resources


data TimerCancelled = TimerCancelled
  deriving stock (Eq, Show)

instance Exception TimerCancelled


data Timer = Timer {
  key :: Unique,
  time :: UTCTime,
  completed :: PromiseEx '[TimerCancelled] (),
  disposer :: Disposer,
  scheduler :: TimerScheduler
}

instance Eq Timer where
  x == y = key x == key y

instance Ord Timer where
  x `compare` y = time x `compare` time y

instance Resource Timer where
  toDisposer Timer{disposer} = disposer

instance IsFuture (Either (Ex '[TimerCancelled]) ()) Timer where
  toFuture Timer{completed} = toFuture completed


data TimerScheduler = TimerScheduler {
  heap :: TMVar (Heap Timer),
  activeCount :: TVar Int,
  cancelledCount :: TVar Int,
  thread :: Async (),
  ioWorker :: TIOWorker,
  exceptionSink :: ExceptionSink
}

instance Resource TimerScheduler where
  toDisposer TimerScheduler{thread} = toDisposer thread

data TimerSchedulerDisposed = TimerSchedulerDisposed
  deriving stock (Eq, Show)

instance Exception TimerSchedulerDisposed

newTimerScheduler :: (MonadQuasar m, MonadIO m) => m TimerScheduler
newTimerScheduler = liftQuasarIO do
  heap <- liftIO $ newTMVarIO empty
  activeCount <- liftIO $ newTVarIO 0
  cancelledCount <- liftIO $ newTVarIO 0
  ioWorker <- askIOWorker
  exceptionSink <- askExceptionSink
  mfix \scheduler -> do
    thread <- startSchedulerThread scheduler
    pure TimerScheduler {
      heap,
      activeCount,
      cancelledCount,
      thread,
      ioWorker,
      exceptionSink
    }

startSchedulerThread :: TimerScheduler -> QuasarIO (Async ())
startSchedulerThread scheduler = async (schedulerThread `finally` liftIO cancelAll)
  where
    heap' :: TMVar (Heap Timer)
    heap' = heap scheduler
    activeCount' = activeCount scheduler
    cancelledCount' = cancelledCount scheduler

    schedulerThread :: QuasarIO ()
    schedulerThread = forever do

      -- Get next timer (blocks when heap is empty)
      nextTimer <- liftIO $ atomically do
        mNext <- uncons <$> readTMVar heap'
        case mNext of
          Nothing -> retry
          Just (timer, _) -> pure timer

      now <- liftIO getCurrentTime

      -- TODO sleep using Posix/Linux create_timer using CLOCK_REALTIME
      let timeUntil = diffUTCTime (time nextTimer) now
      if
        | timeUntil <= 0 -> liftIO $ fireTimers now
        | timeUntil < 60 -> wait nextTimer (ceiling $ toRational timeUntil * 1000000)
        | otherwise -> wait nextTimer (60 * 1000000)

    wait :: Timer -> Int -> QuasarIO ()
    wait nextTimer microseconds = do
      delay <- newDelay microseconds
      awaitAny2 (void $ await delay) nextTimerChanged
      dispose delay
      where
        nextTimerChanged :: Future ()
        nextTimerChanged = unsafeAwaitSTMc do
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
              if time timer <= now
                then do
                  fireTimer timer
                  pure others
                 else pure timers

    fireTimer :: Timer -> STM ()
    fireTimer Timer{completed, disposer} = do
      result <- tryFulfillPromise completed (Right ())
      modifyTVar (if result then activeCount' else cancelledCount') (+ (-1))
      disposeEventually_ disposer

    cleanup :: STM ()
    cleanup = putTMVar heap' . fromList =<< mapMaybeM cleanupTimer . toList =<< takeTMVar heap'

    cleanupTimer :: Timer -> STM (Maybe Timer)
    cleanupTimer timer = do
      cancelled <- ((False <$ awaitSTM (completed timer)) `catch` \TimerCancelled -> pure True) `orElse` pure False
      if cancelled
        then do
          modifyTVar cancelledCount' (+ (-1))
          pure Nothing
        else pure $ Just timer

    cancelAll :: IO ()
    cancelAll = do
      timers <- atomically $ takeTMVar heap'
      mapM_ dispose timers


newTimer :: (MonadQuasar m, MonadIO m, MonadMask m) => TimerScheduler -> UTCTime -> m Timer
newTimer scheduler time = registerNewResource $ newUnmanagedTimer scheduler time


newUnmanagedTimer :: MonadIO m => TimerScheduler -> UTCTime -> m Timer
newUnmanagedTimer scheduler time = liftIO do
  key <- newUnique
  completed <- newPromiseIO
  atomically do
    disposer <- toDisposer <$> newUnmanagedSTMDisposer (disposeFn completed) (ioWorker scheduler) (exceptionSink scheduler)
    let timer = Timer { key, time, completed, disposer, scheduler }
    tryTakeTMVar (heap scheduler) >>= \case
      Just timers -> putTMVar (heap scheduler) (insert timer timers)
      Nothing -> throwM TimerSchedulerDisposed
    modifyTVar (activeCount scheduler) (+ 1)
    pure timer
  where
    disposeFn :: PromiseEx '[TimerCancelled] () -> STM ()
    disposeFn completed = do
      cancelled <- tryFulfillPromise completed (Left (toEx TimerCancelled))
      when cancelled do
        modifyTVar (activeCount scheduler) (+ (-1))
        modifyTVar (cancelledCount scheduler) (+ 1)


sleepUntil :: MonadIO m => TimerScheduler -> UTCTime -> m ()
sleepUntil scheduler time = liftIO do
  result <- bracketOnError (newUnmanagedTimer scheduler time) dispose await
  either throwM pure result


-- | Provides an `IsFuture` instance that can be awaited successfully after a given number of microseconds.
--
-- Based on `threadDelay`. Provides a `IsFuture` and a `IsDisposable` instance.
newtype Delay = Delay (Async ())
  deriving newtype Resource

instance IsFuture (Either (Ex '[TimerCancelled]) ()) Delay where
  toFuture (Delay task) = Bifunctor.first (const (toEx @'[TimerCancelled] TimerCancelled)) <$> toFuture task

newDelay :: (MonadQuasar m, MonadIO m) => Int -> m Delay
newDelay microseconds = Delay <$> async (liftIO (threadDelay microseconds))


-- From package `extra`
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM op = foldr f (pure [])
    where f x xs = do y <- op x; case y of Nothing -> xs; Just z -> do ys <- xs; pure $ z:ys
