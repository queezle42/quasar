module Quasar.Core (
  -- * Async
  IsAsync(..),
  Async,

  -- * AsyncIO
  AsyncIO,
  async,
  await,
  runAsyncIO,
  startAsyncIO,

  -- * AsyncVar
  AsyncVar,
  newAsyncVar,
  putAsyncVar,

  -- * Disposable
  IsDisposable(..),
  disposeIO,
  disposeEventually,
  Disposable,
  mkDisposable,
  synchronousDisposable,
  noDisposable,
) where

import Data.HashMap.Strict qualified as HM
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait promise = do
    mvar <- newEmptyMVar
    onResult_ promise (resultCallback mvar)
    readMVar mvar
    where
      resultCallback :: MVar r -> r -> IO ()
      resultCallback mvar result = do
        success <- tryPutMVar mvar result
        unless success $ fail "Callback was called multiple times"

  -- | Register a callback, that will be called once the promise is settled.
  -- If the promise is already settled, the callback will be called immediately instead.
  --
  -- The returned `Disposable` can be used to deregister the callback.
  onResult
    :: a
    -- ^ async
    -> (r -> IO ())
    -- ^ callback
    -> IO Disposable

  onResult_ :: a -> (r -> IO ()) -> IO ()
  onResult_ x = void . onResult x

  toAsync :: a -> Async r
  toAsync = SomeAsync



data Async r = forall a. IsAsync r a => SomeAsync a

instance IsAsync r (Async r) where
  wait (SomeAsync x) = wait x
  onResult (SomeAsync x) = onResult x
  onResult_ (SomeAsync x) = onResult_ x
  toAsync = id

--instance Functor Async where
--  fmap fn = toAsync . MappedAsync fn
--
--instance Applicative Async where
--  pure = toAsync . CompletedAsync
--  (<*>) pf px = pf >>= \f -> f <$> px
--  liftA2 f px py = px >>= \x -> f x <$> py
--
--instance Monad Async where
--  x >>= y = toAsync $ BindAsync x y
--
--
--instance Semigroup r => Semigroup (Async r) where
--  (<>) = liftA2 (<>)
--
--instance Monoid r => Monoid (Async r) where
--  mempty = pure mempty
--  mconcat = fmap mconcat . sequence

completedAsync :: x -> Async x
completedAsync = toAsync . CompletedAsync



newtype CompletedAsync r = CompletedAsync r
instance IsAsync r (CompletedAsync r) where
  wait (CompletedAsync value) = pure value
  onResult (CompletedAsync value) callback = noDisposable <$ callback value

data MappedAsync r = forall a. MappedAsync (a -> r) (Async a)
instance IsAsync r (MappedAsync r) where
  onResult (MappedAsync fn x) callback = onResult x $ callback . fn
  onResult_ (MappedAsync fn x) callback = onResult_ x $ callback . fn

data BindAsync r = forall a. BindAsync (Async a) (a -> Async r)
instance IsAsync r (BindAsync r) where
  onResult (BindAsync px fn) callback = do
    (disposableMVar :: MVar (Maybe Disposable)) <- newEmptyMVar
    d1 <- onResult px $ \x ->
      modifyMVar_ disposableMVar $ \case
        -- Already disposed
        Nothing -> pure Nothing
        Just _ -> do
          d2 <- onResult (fn x) callback
          pure $ Just d2
    putMVar disposableMVar $ Just d1
    pure $ mkDisposable $ do
      currentDisposable <- liftIO $ readMVar disposableMVar
      dispose currentDisposable
  onResult_ (BindAsync px fn) callback = onResult_ px $ \x -> onResult_ (fn x) callback


-- * AsyncIO

newtype AsyncIO r = AsyncIO (IO (Async r))

instance Functor AsyncIO where
  fmap f = (pure . f =<<)

instance Applicative AsyncIO where
  pure = AsyncIO . pure . completedAsync
  liftA2 f px py = do
    ax <- async px
    y <- py
    x <- await ax
    await $ completedAsync (f x y)
instance Monad AsyncIO where
  lhs >>= fn = AsyncIO $ do
    resultVar <- newAsyncVar
    lhsAsync <- startAsyncIO lhs
    lhsAsync `onResult_` \lhsResult -> do
      rhsAsync <- startAsyncIO $ fn lhsResult
      rhsAsync `onResult_` putAsyncVar resultVar
    pure $ toAsync resultVar

instance MonadIO AsyncIO where
  liftIO = AsyncIO . fmap completedAsync


-- | Run the synchronous part of an `AsyncIO` and then return an `Async` that can be used to wait for completion of the synchronous part.
async :: AsyncIO r -> AsyncIO (Async r)
async = liftIO . startAsyncIO

await :: IsAsync r a => a -> AsyncIO r
await = AsyncIO . pure . toAsync

-- | Run an `AsyncIO` to completion and return the result.
runAsyncIO :: AsyncIO r -> IO r
runAsyncIO = wait <=< startAsyncIO


-- | Run the synchronous part of an `AsyncIO`. Returns an `Async` that can be used to wait for completion of the operation.
startAsyncIO :: AsyncIO r -> IO (Async r)
startAsyncIO (AsyncIO x) = x

-- ** Forking asyncs

--class IsAsyncForkable m where
--  asyncThread :: m r -> AsyncIO r


-- * Async helpers

-- ** AsyncVar

-- | The default implementation for a `Async` that can be fulfilled later.
data AsyncVar r = AsyncVar (MVar r) (MVar (Maybe (HM.HashMap Unique (r -> IO ()))))

instance IsAsync r (AsyncVar r) where
  wait :: AsyncVar r -> IO r
  wait (AsyncVar valueMVar _) = readMVar valueMVar
  onResult :: AsyncVar r -> (r -> IO ()) -> IO Disposable
  onResult (AsyncVar valueMVar callbackMVar) callback =
    modifyMVar callbackMVar $ \case
      Just callbacks -> do
        key <- newUnique
        pure (Just (HM.insert key callback callbacks), removeHandler key)
      Nothing -> (Nothing, noDisposable) <$ (callback =<< readMVar valueMVar)
    where
      removeHandler :: Unique -> Disposable
      removeHandler key = synchronousDisposable $ modifyMVar_ callbackMVar $ pure . fmap (HM.delete key)


newAsyncVar :: MonadIO m => m (AsyncVar r)
newAsyncVar = liftIO $ AsyncVar <$> newEmptyMVar <*> newMVar (Just HM.empty)

putAsyncVar :: MonadIO m => AsyncVar a -> a -> m ()
putAsyncVar (AsyncVar valueMVar callbackMVar) value = liftIO $ do
  success <- tryPutMVar valueMVar value
  unless success $ fail "An AsyncVar can only be fulfilled once"
  callbacks <- modifyMVar callbackMVar (pure . (Nothing, ) . concatMap HM.elems)
  mapM_ ($ value) callbacks


-- ** Async cache

--data CachedAsyncState r = CacheNoCallbacks | CacheHasCallbacks Disposable (HM.HashMap Unique (r -> IO ())) | CacheSettled r
--data CachedAsync r = CachedAsync (Async r) (MVar (CachedAsyncState r))
--
--instance IsAsync r (CachedAsync r) where
--  onResult (CachedAsync baseAsync stateMVar) callback =
--    modifyMVar stateMVar $ \case
--      CacheNoCallbacks -> do
--        key <- newUnique
--        disp <- onResult baseAsync baseAsyncResultCallback
--        pure (CacheHasCallbacks disp (HM.singleton key callback), removeHandler key)
--      CacheHasCallbacks disp callbacks -> do
--        key <- newUnique
--        pure (CacheHasCallbacks disp (HM.insert key callback callbacks), removeHandler key)
--      x@(CacheSettled value) -> (x, noDisposable) <$ callback value
--    where
--      removeHandler :: Unique -> Disposable
--      removeHandler key = mkDisposable $ do
--        state <- liftIO $ takeMVar stateMVar
--        newState <- case state of
--          CacheHasCallbacks disp callbacks -> do
--            let newCallbacks = HM.delete key callbacks
--            if HM.null newCallbacks
--              then CacheNoCallbacks <$ dispose disp
--              else pure (CacheHasCallbacks disp newCallbacks)
--          x -> pure x
--        liftIO $ putMVar stateMVar newState
--      baseAsyncResultCallback :: r -> IO ()
--      baseAsyncResultCallback value = do
--        -- FIXME race condition: mvar is blocked by caller when baseAsync runs synchronous
--        callbacks <- modifyMVar stateMVar $ \case
--          CacheHasCallbacks _ callbacks -> pure (CacheSettled value, HM.elems callbacks)
--          CacheNoCallbacks -> pure (CacheSettled value, [])
--          CacheSettled _ -> fail "Callback was called multiple times"
--        mapM_ ($ value) callbacks
--
--newCachedAsync :: (IsAsync r p, MonadIO m) => p -> m (Async r)
--newCachedAsync x = liftIO $ toAsync . CachedAsync (toAsync x) <$> newMVar CacheNoCallbacks

-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource.
  dispose :: a -> AsyncIO ()

  toDisposable :: a -> Disposable
  toDisposable = mkDisposable . dispose

-- | Dispose a resource in the IO monad.
disposeIO :: IsDisposable a => a -> IO ()
disposeIO = runAsyncIO . dispose

-- | Dispose a resource. Returns without waiting for the resource to be released if possible.
disposeEventually :: IsDisposable a => a -> IO ()
disposeEventually = void . startAsyncIO . dispose

instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose


newtype Disposable = Disposable (AsyncIO ())

instance IsDisposable Disposable where
  dispose (Disposable fn) = fn
  toDisposable = id

instance Semigroup Disposable where
  x <> y = mkDisposable $ liftA2 (<>) (dispose x) (dispose y)

instance Monoid Disposable where
  mempty = mkDisposable $ pure ()
  mconcat disposables = mkDisposable $ traverse_ dispose disposables


mkDisposable :: AsyncIO () -> Disposable
mkDisposable = Disposable

synchronousDisposable :: IO () -> Disposable
synchronousDisposable = mkDisposable . liftIO

noDisposable :: Disposable
noDisposable = mempty
