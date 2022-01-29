module Quasar.Exceptions (
  ExceptionChannel(..),
  throwToExceptionChannel,
  catchInChannel,
  catchAllInChannel,
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
