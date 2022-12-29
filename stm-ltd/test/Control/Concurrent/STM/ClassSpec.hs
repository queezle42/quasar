module Control.Concurrent.STM.ClassSpec (spec) where

import Test.Hspec
import Prelude
import Control.Concurrent.STM.Class
import Control.Exception (IOException)
import Control.Monad.Capability
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Writer

spec :: Spec
spec = describe "Capability system" $ it "compiles" $ True




foopar :: MonadSTMc '[] m => m ()
foopar = execWriterT do
  v <- newTVar True
  b <- readTVar v
  writeTVar v b
  pure ()
--
foo :: STM ()
foo = liftSTMc @STMBaseCapabilities undefined
--
bar :: ReaderT Int STM ()
bar = liftSTMc @STMBaseCapabilities undefined
--
aspf :: MonadSTMc '[Retry] m => m a
aspf = retry

broken :: (MonadSTMc '[ThrowAny] m, HasCapability ThrowAny m) => m ()
broken = flip runReaderT True do
  v <- newTVar True
  b <- readTVar v
  _ <- throwC (userError "foobar")
  --liftSTMc $ throwC (userError "foobar")
  writeTVar v b
  pure ()

works :: STMc '[ThrowAny] ()
works = do
  err
  err2

--works_not :: ThrowAny :< caps => STMc caps ()
--works_not = do
--  err


derived :: MonadSTMc '[Throw IOException] m => m ()
derived = throwC (userError "foobar")

derived2 :: STMc '[ThrowAny] ()
derived2 = do
  throwC (userError "foobar")
  liftSTMc derived3

derived3 :: STMc '[Throw IOException] ()
derived3 = throwC (userError "foobar")

err :: MonadSTMc '[Throw IOException] (STMc caps) => STMc caps ()
err = throwC (userError "foobar")

err2 :: MonadSTMc '[Throw IOException] m => m ()
err2 = do
  throwC (userError "foobar")
  --throwAny (userError "foobar")

err3 :: Throw IOException (STMc caps) => STMc caps ()
err3 = throwC (userError "foobar")


lifted :: (MonadSTMc '[Throw IOException] m) => m ()
lifted = liftSTMc @'[Throw IOException] $ throwC (userError "foobar")
--
--
--broken2 :: (STMcCapabilities caps, ThrowAny :< caps) => STMc caps ()
--broken2 = throwC (userError "foobar")
--
--
foobar2 :: ReaderT Int (STMc '[Retry, ThrowAny]) ()
foobar2 = do
  liftSTMc @'[Retry] retry
  retry
  throwC (userError "foobar")
  foobar
----
----
foobar :: MonadSTMc '[Retry] m => m ()
foobar = do
  retry
--
foobar3 :: MonadSTMc '[Retry, ThrowAny] m => m ()
foobar3 = do
  foobar
  derived
  liftSTMc @'[Retry] retry
--
--
asdf :: STM ()
asdf = do
  foobar
  throwC (userError "foobar")
  liftSTMc @STMBaseCapabilities err
  err2


someFn :: MonadSTMc '[Throw IOException] m => m a
someFn = throwC (userError "foobar")


foo1 :: STM ()
foo1 = someFn

foo2 :: MonadSTM m => m ()
foo2 = someFn

foo3 :: MonadSTMc '[ThrowAny] m => m a
foo3 = do
  someFn
  liftSTMc @'[Throw IOException] do
    someFn


--foo4 :: MonadSTMc '[Throw SomeException] m => m a
--foo4 = someFn

foo5 :: STMc '[ThrowAny] a
foo5 = someFn

