module Quasar.Core (
  IsAsync(..),
  Async,
  cacheAsync,
  AsyncIO,
  async,
  await,
  runAsyncIO,
  startAsyncIO,
  AsyncVar,
  newAsyncVar,
  putAsyncVar,
  IsDisposable(..),
  Disposable,
  mkDisposable,
  synchronousDisposable,
  dummyDisposable,
) where

import Data.HashMap.Strict qualified as HM
import Quasar.Prelude

-- * Async

class IsAsync r a | a -> r where
  -- | Wait until the promise is settled and return the result.
  wait :: a -> IO r
  wait promise = do
    mvar <- newEmptyMVar
    onResult_ promise (callback mvar)
    readMVar mvar
    where
      callback :: MVar r -> r -> IO ()
      callback mvar result = do
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


data Async r
  = forall a. IsAsync r a => SomeAsync a
  -- '| forall a. Async ((r -> IO ()) -> IO Disposable)
  | CompletedAsync r
  | forall a. MappedAsync (a -> r) (Async a)
  | forall a. BindAsync (Async a) (a -> Async r)


instance IsAsync r (Async r) where
  onResult :: Async r -> (r -> IO ()) -> IO Disposable
  onResult (SomeAsync promise) callback = onResult promise callback
  onResult (CompletedAsync result) callback = DummyDisposable <$ callback result
  onResult (MappedAsync fn promise) callback = onResult promise $ callback . fn
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
  onResult_ :: Async r -> (r -> IO ()) -> IO ()
  onResult_ (SomeAsync promise) callback = onResult_ promise callback
  onResult_ (CompletedAsync result) callback = callback result
  onResult_ (MappedAsync fn promise) callback = onResult_ promise $ callback . fn
  onResult_ (BindAsync px fn) callback = onResult_ px $ \x -> onResult_ (fn x) callback
  toAsync = id

instance Functor Async where
  fmap fn promise = MappedAsync fn promise

instance Applicative Async where
  pure = CompletedAsync
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py

instance Monad Async where
  (>>=) = BindAsync


instance Semigroup r => Semigroup (Async r) where
  (<>) = liftA2 (<>)

instance Monoid r => Monoid (Async r) where
  mempty = pure mempty
  mconcat = fmap mconcat . sequence



newtype AsyncIO r = AsyncIO (IO (Async r))

instance Functor AsyncIO where
  fmap f (AsyncIO x) = AsyncIO (f <<$>> x)
instance Applicative AsyncIO where
  pure = AsyncIO . pure . pure
  (<*>) pf px = pf >>= \f -> f <$> px
  liftA2 f px py = px >>= \x -> f x <$> py
instance Monad AsyncIO where
  lhs >>= fn = AsyncIO $ do
    resultVar <- newAsyncVar
    lhsAsync <- startAsyncIO lhs
    lhsAsync `onResult_` \lhsResult -> do
      rhsAsync <- startAsyncIO $ fn lhsResult
      rhsAsync `onResult_` putAsyncVar resultVar
    pure $ toAsync resultVar

instance MonadIO AsyncIO where
  liftIO = AsyncIO . fmap pure


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


-- ** Async implementation

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
      Nothing -> (Nothing, DummyDisposable) <$ (callback =<< readMVar valueMVar)
    where
      removeHandler :: Unique -> Disposable
      removeHandler key = synchronousDisposable $ modifyMVar_ callbackMVar $ pure . fmap (HM.delete key)


newAsyncVar :: IO (AsyncVar r)
newAsyncVar = do
  valueMVar <- newEmptyMVar
  callbackMVar <- newMVar $ Just HM.empty
  pure $ AsyncVar valueMVar callbackMVar

putAsyncVar :: AsyncVar a -> a -> IO ()
putAsyncVar (AsyncVar valueMVar callbackMVar) value = do
  success <- tryPutMVar valueMVar value
  unless success $ fail "A promise can only be fulfilled once"
  putMVar valueMVar value
  callbacks <- modifyMVar callbackMVar (pure . (Nothing, ) . concatMap HM.elems)
  mapM_ ($ value) callbacks


-- ** Async cache

data CachedAsyncState r = CacheNoCallbacks | CacheHasCallbacks Disposable (HM.HashMap Unique (r -> IO ())) | CacheSettled r
data CachedAsync r = CachedAsync (Async r) (MVar (CachedAsyncState r))

instance IsAsync r (CachedAsync r) where
  onResult (CachedAsync baseAsync stateMVar) callback =
    modifyMVar stateMVar $ \case
      CacheNoCallbacks -> do
        key <- newUnique
        disp <- onResult baseAsync fulfillCache
        pure (CacheHasCallbacks disp (HM.singleton key callback), removeHandler key)
      CacheHasCallbacks disp callbacks -> do
        key <- newUnique
        pure (CacheHasCallbacks disp (HM.insert key callback callbacks), removeHandler key)
      x@(CacheSettled value) -> (x, DummyDisposable) <$ callback value
    where
      removeHandler :: Unique -> Disposable
      removeHandler key = synchronousDisposable $ modifyMVar_ stateMVar $ \case
        CacheHasCallbacks disp callbacks -> do
          let newCallbacks = HM.delete key callbacks
          if HM.null newCallbacks
            then CacheNoCallbacks <$ disposeBlocking disp
            else pure (CacheHasCallbacks disp newCallbacks)
        state -> pure state
      fulfillCache :: r -> IO ()
      fulfillCache value = do
        callbacks <- modifyMVar stateMVar $ \case
          CacheHasCallbacks _ callbacks -> pure (CacheSettled value, HM.elems callbacks)
          CacheNoCallbacks -> pure (CacheSettled value, [])
          CacheSettled _ -> fail "Callback was called multiple times"
        mapM_ ($ value) callbacks

cacheAsync :: IsAsync r p => p -> IO (Async r)
cacheAsync promise = toAsync . CachedAsync (toAsync promise) <$> newMVar CacheNoCallbacks

-- * Disposable

class IsDisposable a where
  -- TODO document laws: must not throw exceptions, is idempotent

  -- | Dispose a resource. When the resource has been released the promise is fulfilled.
  dispose :: a -> AsyncIO ()
  dispose = liftIO . disposeBlocking
  -- | Dispose a resource. Returns without waiting for the resource to be released.
  disposeEventually :: a -> IO ()
  disposeEventually = void . startAsyncIO . dispose
  -- | Dispose a resource. Blocks until the resource is released.
  disposeBlocking :: a -> IO ()
  disposeBlocking = runAsyncIO . dispose

  toDisposable :: a -> Disposable
  toDisposable = SomeDisposable

  {-# MINIMAL dispose | disposeBlocking #-}

instance IsDisposable a => IsDisposable (Maybe a) where
  dispose = mapM_ dispose
  disposeEventually = mapM_ disposeEventually
  disposeBlocking = mapM_ disposeBlocking


data Disposable
  = forall a. IsDisposable a => SomeDisposable a
  | Disposable (AsyncIO ())
  | MultiDisposable [Disposable]
  | DummyDisposable

instance IsDisposable Disposable where
  dispose (SomeDisposable x) = dispose x
  dispose (Disposable fn) = fn
  dispose (MultiDisposable disposables) = mconcat <$> mapM dispose disposables
  dispose DummyDisposable = pure ()

  disposeEventually (SomeDisposable x) = disposeEventually x
  disposeEventually x = void . startAsyncIO . dispose $ x

  disposeBlocking (SomeDisposable x) = disposeBlocking x
  disposeBlocking x = runAsyncIO . dispose $ x

  toDisposable = id

instance Semigroup Disposable where
  MultiDisposable x <> MultiDisposable y = MultiDisposable (x <> y)
  x <> MultiDisposable y = MultiDisposable (x : y)
  x <> y = MultiDisposable [x, y]

instance Monoid Disposable where
  mempty = DummyDisposable
  mconcat = MultiDisposable


mkDisposable :: AsyncIO () -> Disposable
mkDisposable = Disposable

synchronousDisposable :: IO () -> Disposable
synchronousDisposable = mkDisposable . liftIO

dummyDisposable :: Disposable
dummyDisposable = mempty
