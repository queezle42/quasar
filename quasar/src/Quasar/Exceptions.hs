module Quasar.Exceptions (
  ExceptionSink(..),
  throwToExceptionSink,
  throwToExceptionSinkIO,
  catchSink,
  catchAllSink,

  -- * Exceptions
  CancelAsync(..),
  AsyncDisposed(..),
  AsyncException(..),
  isCancelAsync,
  isAsyncDisposed,
  DisposeException(..),
  isDisposeException,
  FailedToAttachResource(..),
  isFailedToAttachResource,
  AlreadyDisposing(..),
  isAlreadyDisposing,
  PromiseAlreadyCompleted(..),
) where

import Control.Monad.Catch
import Quasar.Prelude


newtype ExceptionSink = ExceptionSink (SomeException -> STMc NoRetry '[] ())


throwToExceptionSink :: (Exception e, MonadSTMc NoRetry '[] m) => ExceptionSink -> e -> m ()
throwToExceptionSink (ExceptionSink channelFn) ex = liftSTMc $ channelFn (toException ex)

throwToExceptionSinkIO :: (Exception e, MonadIO m) => ExceptionSink -> e -> m ()
throwToExceptionSinkIO sink ex = atomically $ throwToExceptionSink sink ex

catchSink :: forall e. Exception e => (e -> STMc NoRetry '[SomeException] ()) -> ExceptionSink -> ExceptionSink
catchSink handler parentSink = ExceptionSink \ex ->
  case fromException ex of
    Just matchedException -> wrappedHandler matchedException
    Nothing -> throwToExceptionSink parentSink ex
  where
    wrappedHandler :: e -> STMc NoRetry '[] ()
    wrappedHandler ex = handler ex `catchAllSTMc` throwToExceptionSink parentSink


catchAllSink :: (SomeException -> STMc NoRetry '[SomeException] ()) -> ExceptionSink -> ExceptionSink
catchAllSink = catchSink


newtype CancelAsync = CancelAsync Unique
  deriving stock Eq
instance Show CancelAsync where
  show _ = "CancelAsync"
instance Exception CancelAsync where

data AsyncDisposed = AsyncDisposed
  deriving stock (Eq, Show)
instance Exception AsyncDisposed where

-- TODO Needs a descriptive name. This is similar in functionality to `ExceptionThrownInLinkedThread`
newtype AsyncException = AsyncException SomeException
  deriving stock Show
  deriving anyclass Exception


isCancelAsync :: SomeException -> Bool
isCancelAsync (fromException @CancelAsync -> Just _) = True
isCancelAsync _ = False

isAsyncDisposed :: SomeException -> Bool
isAsyncDisposed (fromException @AsyncDisposed -> Just _) = True
isAsyncDisposed _ = False



newtype DisposeException = DisposeException SomeException
  deriving stock Show

instance Exception DisposeException where
  displayException (DisposeException inner) = "Exception was thrown while disposing a resource: " <> displayException inner

isDisposeException :: SomeException -> Bool
isDisposeException (fromException @DisposeException -> Just _) = True
isDisposeException _ = False



data FailedToAttachResource = FailedToAttachResource
  deriving stock (Eq, Show)

instance Exception FailedToAttachResource where
  displayException FailedToAttachResource =
    "FailedToRegisterResource: Failed to attach a resource to a resource manager. This might result in leaked resources if left unhandled."

isFailedToAttachResource :: SomeException -> Bool
isFailedToAttachResource (fromException @FailedToAttachResource -> Just _) = True
isFailedToAttachResource _ = False


data AlreadyDisposing = AlreadyDisposing
  deriving stock (Eq, Show)

instance Exception AlreadyDisposing where
  displayException AlreadyDisposing =
    "AlreadyDisposing: Failed to create a resource because the resource manager it should be attached to is already disposing."

isAlreadyDisposing :: SomeException -> Bool
isAlreadyDisposing (fromException @AlreadyDisposing -> Just _) = True
isAlreadyDisposing _ = False



data PromiseAlreadyCompleted = PromiseAlreadyCompleted
  deriving stock Show
  deriving anyclass Exception
