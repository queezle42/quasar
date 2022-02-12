module Quasar.Utils.ShortIO (
  ShortIO,
  runShortIO,
  unsafeShortIO,

  forkIOShortIO,
  forkIOWithUnmaskShortIO,
  throwToShortIO,

  -- ** Some specific functions required internally
  peekAwaitableShortIO,
  putAsyncVarShortIO_,
) where

import Control.Monad.Catch
import Quasar.Awaitable
import Quasar.Prelude
import Control.Concurrent

newtype ShortIO a = ShortIO (IO a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadMask)

runShortIO :: ShortIO a -> IO a
runShortIO (ShortIO fn) = fn

unsafeShortIO :: IO a -> ShortIO a
unsafeShortIO = ShortIO


forkIOShortIO :: IO () -> ShortIO ThreadId
forkIOShortIO fn = ShortIO $ forkIO fn

forkIOWithUnmaskShortIO :: ((forall a. IO a -> IO a) -> IO ()) -> ShortIO ThreadId
forkIOWithUnmaskShortIO fn = ShortIO $ forkIOWithUnmask fn

throwToShortIO :: Exception e => ThreadId -> e -> ShortIO ()
throwToShortIO tid ex = ShortIO $ throwTo tid ex


peekAwaitableShortIO :: Awaitable r -> ShortIO (Maybe r)
peekAwaitableShortIO awaitable = ShortIO $ peekAwaitable awaitable

putAsyncVarShortIO_ :: AsyncVar a -> a -> ShortIO ()
putAsyncVarShortIO_ var value = ShortIO $ putAsyncVar_ var value
