module Quasar.Utils.ReaderLock (
  ReaderLock,
  newReaderLock,
  newRecursiveReaderLock,
  withReaderLock,
  tryDestroyReaderLock,
  ReaderLockDestroyed,
  isReaderLockDestroyed,
) where

import Control.Monad.Catch
import Quasar.Prelude

data ReaderLockDestroyed = ReaderLockDestroyed
  deriving stock Show
  deriving anyclass Exception

isReaderLockDestroyed :: ReaderLockDestroyed -> Bool
isReaderLockDestroyed ReaderLockDestroyed = True

data ReaderLockInvalidOperation = ReaderLockInvalidOperation
  deriving stock Show
  deriving anyclass Exception

data ReaderLockState
  = Valid Word64 (STM ()) (STM ())
  | Destroyed

data ReaderLock = ReaderLock (TVar ReaderLockState)

newReaderLock :: STM () -> STM () -> STM ReaderLock
newReaderLock lock unlock =
  ReaderLock <$> newTVar (Valid 0 lock unlock)

newRecursiveReaderLock :: ReaderLock -> STM ReaderLock
newRecursiveReaderLock parent = newReaderLock lock unlock
  where
    lock = unsafeLockReaderLock parent
    unlock = unsafeUnlockReaderLock parent

unsafeLockReaderLock :: ReaderLock -> STM ()
unsafeLockReaderLock (ReaderLock var) = do
  readTVar var >>= \case
    Valid counter lock unlock -> do
      when (counter == 0) lock
      writeTVar var $ Valid (counter + 1) lock unlock
    Destroyed -> throwM ReaderLockDestroyed

unsafeUnlockReaderLock :: ReaderLock -> STM ()
unsafeUnlockReaderLock (ReaderLock var) = do
  readTVar var >>= \case
    Valid 0 _ _ -> throwM ReaderLockInvalidOperation
    Valid 1 lock unlock -> do
      unlock
      writeTVar var $ Valid 0 lock unlock
    Valid counter lock unlock ->
      writeTVar var $ Valid (counter - 1) lock unlock
    Destroyed -> throwM ReaderLockDestroyed

tryDestroyReaderLock :: ReaderLock -> STM Bool
tryDestroyReaderLock (ReaderLock var) =
  stateTVar var
    \case
      Valid 0 _ _ -> (True, Destroyed)
      Destroyed -> (True, Destroyed)
      state -> (False, state)

withReaderLock :: (MonadIO m, MonadMask m) => ReaderLock -> m a -> m a
withReaderLock cl fn =
  bracket
    (atomically $ unsafeLockReaderLock cl)
    (\() -> atomically $ unsafeUnlockReaderLock cl)
    (\() -> fn)
