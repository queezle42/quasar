{-# LANGUAGE UndecidableSuperClasses #-}

module Quasar.Network.Runtime (
  -- * Interacting with objects over network
  NetworkObject(..),
  IsNetworkStrategy(..),
  provideObjectAsMessagePart,
  provideObjectAsDisposableMessagePart,
  receiveObjectFromMessagePart,
  NetworkReference(..),
  NetworkRootReference(..),

  -- * Observable
  ObservableState(..),
  joinNetworkObservable,
) where

import Quasar.Network.Runtime.Class
import Quasar.Network.Runtime.Function ()
import Quasar.Network.Runtime.Future ()
import Quasar.Network.Runtime.Generic ()
import Quasar.Network.Runtime.Observable
