module Quasar.Exceptions (
  ExceptionChannel(..),
  throwToExceptionChannel,
  catchInChannel,
  catchAllInChannel,

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
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Quasar.Prelude


newtype ExceptionChannel = ExceptionChannel (SomeException -> STM ())


throwToExceptionChannel :: Exception e => ExceptionChannel -> e -> STM ()
throwToExceptionChannel (ExceptionChannel channelFn) ex = channelFn (toException ex)

-- TODO better name?
catchInChannel :: forall e. Exception e => (e -> STM ()) -> ExceptionChannel -> ExceptionChannel
catchInChannel handler parentChannel = ExceptionChannel $ mapM_ wrappedHandler . fromException
  where
    wrappedHandler :: e -> STM ()
    wrappedHandler ex = catchAll (handler ex) (throwToExceptionChannel parentChannel)


catchAllInChannel :: (SomeException -> STM ()) -> ExceptionChannel -> ExceptionChannel
catchAllInChannel = catchInChannel


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
