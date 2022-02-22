module Quasar.Monad (
  -- * Quasar
  Quasar,
  newQuasar,

  MonadQuasar(..),

  QuasarT,
  QuasarIO,
  QuasarSTM,

  withQuasarGeneric,
  runQuasarIO,
  liftQuasarIO,
  quasarAtomically,

  enterQuasarIO,
  enterQuasarSTM,

  startShortIO_,

  -- ** High-level initialization
  runQuasarAndExit,
  runQuasarAndExitWith,
  runQuasarCollectExceptions,
  runQuasarCombineExceptions,

  -- ** Get quasar components
  quasarIOWorker,
  quasarExceptionChannel,
  quasarResourceManager,
  askIOWorker,
  askExceptionChannel,
  askResourceManager,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.List.NonEmpty
import GHC.Records (HasField(..))
import Quasar.Async.STMHelper
import Quasar.Awaitable
import Quasar.Exceptions
import Quasar.Exceptions.ExceptionChannel
import Quasar.Prelude
import Quasar.Resources.Disposer
import Quasar.Utils.Exceptions
import Quasar.Utils.ShortIO
import System.Exit
import Data.Bifunctor (first)


-- Invariant: the resource manager is disposed as soon as an exception is thrown to the channel
data Quasar = Quasar TIOWorker ExceptionChannel ResourceManager

instance Resource Quasar where
  getDisposer (Quasar _ _ rm) = getDisposer rm

instance HasField "ioWorker" Quasar TIOWorker where
  getField = quasarIOWorker

instance HasField "exceptionChannel" Quasar ExceptionChannel where
  getField = quasarExceptionChannel

instance HasField "resourceManager" Quasar ResourceManager where
  getField = quasarResourceManager

quasarIOWorker :: Quasar -> TIOWorker
quasarIOWorker (Quasar worker _ _) = worker

quasarExceptionChannel :: Quasar -> ExceptionChannel
quasarExceptionChannel (Quasar _ exChan _) = exChan

quasarResourceManager :: Quasar -> ResourceManager
quasarResourceManager (Quasar _ _ rm) = rm

newQuasarSTM :: TIOWorker -> ExceptionChannel -> ResourceManager -> STM Quasar
newQuasarSTM worker parentExChan parentRM = do
  rm <- newUnmanagedResourceManagerSTM worker parentExChan
  attachResource parentRM rm
  pure $ Quasar worker (ExceptionChannel (disposeOnException rm)) rm
  where
    disposeOnException :: ResourceManager -> SomeException -> STM ()
    disposeOnException rm ex = do
      disposeEventuallySTM_ rm
      throwToExceptionChannel parentExChan ex

newQuasar :: MonadQuasar m => m Quasar
newQuasar = do
  worker <- askIOWorker
  exChan <- askExceptionChannel
  parentRM <- askResourceManager
  ensureSTM $ newQuasarSTM worker exChan parentRM


--withResourceScope :: MonadQuasar m => m a -> m a


class (MonadCatch m, MonadFix m) => MonadQuasar m where
  askQuasar :: m Quasar
  maskIfRequired :: m a -> m a
  startShortIO :: ShortIO a -> m (Awaitable a)
  ensureSTM :: STM a -> m a
  ensureQuasarSTM :: QuasarSTM a -> m a
  localQuasar :: Quasar -> m a -> m a

type QuasarT = ReaderT Quasar
type QuasarIO = QuasarT IO

newtype QuasarSTM a = QuasarSTM (ReaderT (Quasar, TVar (Awaitable ())) STM a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadFix, Alternative)


instance (MonadIO m, MonadMask m, MonadFix m) => MonadQuasar (QuasarT m) where
  askQuasar = ask
  ensureSTM t = liftIO (atomically t)
  maskIfRequired = mask_
  startShortIO fn = do
    exChan <- askExceptionChannel
    liftIO $ uninterruptibleMask_ $ try (runShortIO fn) >>= \case
      Left ex -> do
        atomically $ throwToExceptionChannel exChan ex
        pure $ throwM $ toException $ AsyncException ex
      Right result -> pure $ pure result
  ensureQuasarSTM = quasarAtomically
  localQuasar quasar = local (const quasar)


instance MonadQuasar QuasarSTM where
  askQuasar = QuasarSTM (asks fst)
  ensureSTM fn = QuasarSTM (lift fn)
  maskIfRequired = id
  startShortIO fn = do
    (quasar, effectAwaitableVar) <- QuasarSTM ask
    let
      worker = quasarIOWorker quasar
      exChan = quasarExceptionChannel quasar

    ensureSTM do
      awaitable <- startShortIOSTM fn worker exChan
      -- Await in reverse order, so it is almost guaranteed this only retries once
      modifyTVar effectAwaitableVar (awaitSuccessOrFailure awaitable *>)
      pure awaitable
  ensureQuasarSTM = id
  localQuasar quasar (QuasarSTM fn) = QuasarSTM (local (first (const quasar)) fn)


-- Overlappable so a QuasarT has priority over the base monad.
instance {-# OVERLAPPABLE #-} MonadQuasar m => MonadQuasar (ReaderT r m) where
  askQuasar = lift askQuasar
  ensureSTM t = lift (ensureSTM t)
  maskIfRequired fn = do
    x <- ask
    lift $ maskIfRequired (runReaderT fn x)
  startShortIO t = lift (startShortIO t)
  ensureQuasarSTM t = lift (ensureQuasarSTM t)
  localQuasar quasar fn = do
    x <- ask
    lift (localQuasar quasar (runReaderT fn x))

-- TODO MonadQuasar instances for StateT, WriterT, RWST, MaybeT, ...


startShortIO_ :: MonadQuasar m => ShortIO () -> m ()
startShortIO_ fn = void $ startShortIO fn

askIOWorker :: MonadQuasar m => m TIOWorker
askIOWorker = quasarIOWorker <$> askQuasar

askExceptionChannel :: MonadQuasar m => m ExceptionChannel
askExceptionChannel = quasarExceptionChannel <$> askQuasar

askResourceManager :: MonadQuasar m => m ResourceManager
askResourceManager = quasarResourceManager <$> askQuasar


liftQuasarIO :: (MonadIO m, MonadQuasar m) => QuasarIO a -> m a
liftQuasarIO fn = do
  quasar <- askQuasar
  liftIO $ runReaderT fn quasar

runQuasarIO :: MonadIO m => Quasar -> QuasarIO a -> m a
runQuasarIO quasar fn = liftIO $ runReaderT fn quasar

quasarAtomically :: (MonadQuasar m, MonadIO m) => QuasarSTM a -> m a
quasarAtomically (QuasarSTM fn) = do
 quasar <- askQuasar
 liftIO do
   await =<< atomically do
     effectAwaitableVar <- newTVar (pure ())
     result <- runReaderT fn (quasar, effectAwaitableVar)
     (result <$) <$> readTVar effectAwaitableVar

enterQuasarIO :: MonadIO m => Quasar -> QuasarIO () -> m ()
enterQuasarIO quasar fn = runQuasarIO quasar $ redirectExceptionToSink_ fn

enterQuasarSTM :: MonadQuasar m => Quasar -> QuasarSTM () -> m ()
enterQuasarSTM quasar fn = ensureQuasarSTM $ localQuasar quasar $ redirectExceptionToSink_ fn


redirectExceptionToSink :: MonadQuasar m => m a -> m (Maybe a)
redirectExceptionToSink fn = do
  exChan <- askExceptionChannel
  (Just <$> fn) `catchAll`
    \ex -> ensureSTM (Nothing <$ throwToExceptionChannel exChan ex)

redirectExceptionToSink_ :: MonadQuasar m => m a -> m ()
redirectExceptionToSink_ fn = void $ redirectExceptionToSink fn


-- * Quasar initialization

withQuasarGeneric :: TIOWorker -> ExceptionChannel -> QuasarIO a -> IO a
withQuasarGeneric worker exChan fn = mask \unmask -> do
  rm <- atomically $ newUnmanagedResourceManagerSTM worker exChan
  let quasar = Quasar worker exChan rm
  unmask (runQuasarIO quasar fn) `finally` dispose rm


-- * High-level entry helpers

runQuasarAndExit :: QuasarIO () -> IO a
runQuasarAndExit =
  runQuasarAndExitWith \case
   QuasarExitSuccess () -> ExitSuccess
   QuasarExitAsyncException () -> ExitFailure 1
   QuasarExitMainThreadFailed -> ExitFailure 1

data QuasarExitState a = QuasarExitSuccess a | QuasarExitAsyncException a | QuasarExitMainThreadFailed

runQuasarAndExitWith :: (QuasarExitState a -> ExitCode) -> QuasarIO a -> IO b
runQuasarAndExitWith exitCodeFn fn = mask \unmask -> do
  worker <- newTIOWorker
  (exChan, exceptionWitness) <- atomically $ newExceptionChannelWitness (loggingExceptionChannel worker)
  mResult <- unmask $ withQuasarGeneric worker exChan (redirectExceptionToSink fn)
  failure <- atomically exceptionWitness
  exitState <- case (mResult, failure) of
    (Just result, False) -> pure $ QuasarExitSuccess result
    (Just result, True) -> pure $ QuasarExitAsyncException result
    (Nothing, True) -> pure QuasarExitMainThreadFailed
    (Nothing, False) -> do
      traceIO "Invalid code path reached: Main thread failed but no asynchronous exception was witnessed. This is a bug, please report it to the `quasar`-project."
      pure QuasarExitMainThreadFailed
  exitWith $ exitCodeFn exitState


runQuasarCollectExceptions :: QuasarIO a -> IO (Either SomeException a, [SomeException])
runQuasarCollectExceptions fn = do
  (exChan, collectExceptions) <- atomically $ newExceptionCollector panicChannel
  worker <- newTIOWorker
  result <- try $ withQuasarGeneric worker exChan fn
  exceptions <- atomically collectExceptions
  pure (result, exceptions)

runQuasarCombineExceptions :: QuasarIO a -> IO a
runQuasarCombineExceptions fn = do
  (result, exceptions) <- runQuasarCollectExceptions fn
  case result of
    Left (ex :: SomeException) -> maybe (throwM ex) (throwM . CombinedException . (ex <|)) (nonEmpty exceptions)
    Right fnResult -> maybe (pure fnResult) (throwM . CombinedException) $ nonEmpty exceptions
