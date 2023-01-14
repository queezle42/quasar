module Control.Concurrent.STM.ClassSpec (spec) where

import Test.Hspec
import Prelude
import Control.Concurrent.STM.Class
import Control.Exception (Exception, SomeException, IOException)
import Control.Exception.Ex
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Writer

data A = A
  deriving (Show)

instance Exception A

data B = B
  deriving (Show)

instance Exception B

data C = C
  deriving (Show)

instance Exception C

spec :: Spec
spec = describe "Capability system" $ it "compiles" $ True

abc :: MonadSTMc NoRetry '[A, B, C] m => m ()
abc = do
  throwSTM B
  throwSTM C
  throwSTM A
  throwEx (toEx @'[A, C] C)

foopar :: MonadSTMc NoRetry '[] m => m ()
foopar = execWriterT do
  v <- newTVar True
  b <- readTVar v
  writeTVar v b
  pure ()

foo :: STM ()
foo = liftSTMc @Retry @'[SomeException] undefined

bar :: ReaderT Int STM ()
bar = liftSTMc @Retry @'[SomeException] undefined

aspf :: MonadSTMc Retry '[] m => m a
aspf = retry

broken :: MonadSTMc NoRetry '[SomeException] m => m ()
broken = flip runReaderT True do
  v <- newTVar True
  b <- readTVar v
  _ <- throwSTM (userError "foobar")
  --liftSTMc $ throwSTM (userError "foobar")
  writeTVar v b
  pure ()

works :: STMc NoRetry '[SomeException] ()
works = do
  err
  err2

derived :: MonadSTMc NoRetry '[IOException] m => m ()
derived = throwSTM (userError "foobar")

derived2 :: STMc NoRetry '[SomeException] ()
derived2 = do
  throwSTM (userError "foobar")
  throwSTM A
  liftSTMc derived3

derived3 :: STMc NoRetry '[IOException] ()
derived3 = throwSTM (userError "foobar")

err :: MonadSTMc NoRetry '[IOException] (STMc a b) => STMc a b ()
err = throwSTM (userError "foobar")

err2 :: MonadSTMc NoRetry '[IOException] m => m ()
err2 = do
  throwSTM (userError "foobar")
  -- Should not compile:
  --throwSTM A

err3 :: MonadSTMc NoRetry '[IOException] (STMc a b) => STMc a b ()
err3 = throwSTM (userError "foobar")


lifted :: (MonadSTMc NoRetry '[IOException] m) => m ()
lifted = liftSTMc @NoRetry @'[IOException] $ throwSTM (userError "foobar")

foobar2 :: ReaderT Int (STMc Retry '[SomeException]) ()
foobar2 = do
  liftSTMc @Retry @'[] retry
  retry
  throwSTM (userError "foobar")
  foobar

foobar2_1 :: ReaderT Int (STMc Retry '[A]) ()
foobar2_1 = do
  liftSTMc @Retry @'[] retry
  retry
  throwSTM A
  foobar


foobar :: MonadSTMc Retry '[] m => m ()
foobar = do
  retry

foobar3 :: MonadSTMc Retry '[SomeException] m => m ()
foobar3 = do
  foobar
  derived
  liftSTMc @Retry @'[] retry


asdf :: STM ()
asdf = do
  foobar
  throwSTM (userError "foobar")
  liftSTMc @NoRetry @'[IOException] err
  err2


someFn :: MonadSTMc NoRetry '[IOException] m => m a
someFn = throwSTM (userError "foobar")


foo1 :: STM ()
foo1 = someFn

foo2 :: MonadSTM m => m ()
foo2 = someFn

foo3 :: MonadSTMc NoRetry '[SomeException] m => m a
foo3 = do
  someFn
  liftSTMc @NoRetry @'[IOException] do
    someFn

foo5 :: STMc NoRetry '[SomeException] a
foo5 = someFn
