module Quasar.Subscribable (
  SubscribableMessage(..),
  IsSubscribable(..),
  Subscribable,
  SubscribableEvent,
  newSubscribableEvent,
  raiseSubscribableEvent,
) where

import Control.Concurrent.STM
import Control.Monad.Catch
import Control.Monad.Reader
import Data.HashMap.Strict qualified as HM
import Quasar.Awaitable
import Quasar.Disposable
import Quasar.Prelude
import Quasar.ResourceManager


data SubscribableMessage r
  = SubscribableUpdate r
  | SubscribableNotAvailable SomeException
  deriving stock (Show, Generic)
instance Functor SubscribableMessage where
  fmap fn (SubscribableUpdate r) = SubscribableUpdate (fn r)
  fmap _ (SubscribableNotAvailable ex) = SubscribableNotAvailable ex


class IsSubscribable r a | a -> r where
  toSubscribable :: a -> Subscribable r
  toSubscribable x = Subscribable x

  subscribe
    :: (MonadResourceManager m, MonadIO m, MonadMask m)
    => a
    -> (SubscribableMessage r -> ResourceManagerIO (Awaitable ()))
    -> m ()
  subscribe x = subscribe (toSubscribable x)
  {-# MINIMAL toSubscribable | subscribe #-}

data Subscribable r where
  Subscribable :: IsSubscribable r a => a -> Subscribable r
  MappedSubscribable :: IsSubscribable a o => (a -> r) -> o -> Subscribable r
  MultiSubscribable :: [Subscribable r] -> Subscribable r

instance IsSubscribable r (Subscribable r) where
  toSubscribable = id
  subscribe (Subscribable x) callback = subscribe x callback
  subscribe (MappedSubscribable fn x) callback = subscribe x (callback . fmap fn)
  subscribe (MultiSubscribable xs) callback = forM_ xs (`subscribe` callback)

instance Functor Subscribable where
  fmap fn (Subscribable x) = MappedSubscribable fn x
  fmap fn (MappedSubscribable fn2 x) = MappedSubscribable (fn . fn2) x
  fmap fn x@(MultiSubscribable _) = MappedSubscribable fn x

instance Semigroup (Subscribable r) where
  MultiSubscribable [] <> x = x
  x <> MultiSubscribable [] = x
  MultiSubscribable as <> MultiSubscribable bs = MultiSubscribable $ as <> bs
  MultiSubscribable as <> b = MultiSubscribable $ as <> [b]
  a <> MultiSubscribable bs = MultiSubscribable $ [a] <> bs
  a <> b = MultiSubscribable [a, b]

instance Monoid (Subscribable r) where
  mempty = MultiSubscribable []


newtype SubscribableEvent r = SubscribableEvent (TVar (HM.HashMap Unique (SubscribableMessage r -> IO (Awaitable()))))
instance IsSubscribable r (SubscribableEvent r) where
  subscribe (SubscribableEvent tvar) callback = mask_ do
    key <- liftIO newUnique
    resourceManager <- askResourceManager
    runInResourceManagerSTM do
      registerDisposable =<< lift do
        callbackMap <- readTVar tvar
        writeTVar tvar $ HM.insert key (\msg -> runReaderT (callback msg) resourceManager) callbackMap
        newDisposable (disposeFn key)
      where
        disposeFn :: Unique -> IO ()
        disposeFn key = atomically do
          callbackMap <- readTVar tvar
          writeTVar tvar $ HM.delete key callbackMap


newSubscribableEvent :: MonadIO m => m (SubscribableEvent r)
newSubscribableEvent = liftIO $ SubscribableEvent <$> newTVarIO HM.empty

raiseSubscribableEvent :: MonadIO m => SubscribableEvent r -> r -> m ()
raiseSubscribableEvent (SubscribableEvent tvar) r = liftIO do
  callbackMap <- readTVarIO tvar
  awaitables <- forM (HM.elems callbackMap) \callback -> do
    callback $ SubscribableUpdate r
  await $ mconcat awaitables
