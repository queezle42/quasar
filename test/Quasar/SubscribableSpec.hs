module Quasar.SubscribableSpec (
  spec,
) where

import Control.Concurrent.STM
import Quasar.Prelude
import Quasar.ResourceManager
import Quasar.Subscribable
import Test.Hspec


spec :: Spec
spec = do
  describe "SubscribableEvent" $ parallel do

    it "can be subscribed" $ io $ withResourceManagerM do
      event <- newSubscribableEvent
      resultVar <- liftIO newEmptyTMVarIO
      subscribe event $ liftIO . \case
        SubscribableUpdate r -> atomically (putTMVar resultVar r) >> mempty
        SubscribableNotAvailable ex -> throwIO ex
      raiseSubscribableEvent event (42 :: Int)
      liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Just 42

    it "stops calling the callback after the subscription is disposed" $ io $ withResourceManagerM do
      event <- newSubscribableEvent
      resultVar <- liftIO $ newEmptyTMVarIO
      withSubResourceManagerM do
        subscribe event $ liftIO . \case
          SubscribableUpdate r -> atomically (putTMVar resultVar r) >> mempty
          SubscribableNotAvailable ex -> throwIO ex
        raiseSubscribableEvent event (42 :: Int)
        liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Just 42
      raiseSubscribableEvent event (21 :: Int)
      liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Nothing

    it "can be fmap'ed" $ io $ withResourceManagerM do
      event <- newSubscribableEvent
      let subscribable = (* 2) <$> toSubscribable event
      resultVar <- liftIO $ newEmptyTMVarIO
      subscribe subscribable $ liftIO . \case
        SubscribableUpdate r -> atomically (putTMVar resultVar r) >> mempty
        SubscribableNotAvailable ex -> throwIO ex
      raiseSubscribableEvent event (21 :: Int)
      liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Just 42

    it "can be combined with other events" $ io $ withResourceManagerM do
      event1 <- newSubscribableEvent
      event2 <- newSubscribableEvent
      let subscribable = toSubscribable event1 <> toSubscribable event2
      resultVar <- liftIO $ newEmptyTMVarIO
      subscribe subscribable $ liftIO . \case
        SubscribableUpdate r -> atomically (putTMVar resultVar r) >> mempty
        SubscribableNotAvailable ex -> throwIO ex
      raiseSubscribableEvent event1 (21 :: Int)
      liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Just 21
      raiseSubscribableEvent event2 (42 :: Int)
      liftIO $ atomically (tryTakeTMVar resultVar) `shouldReturn` Just 42
