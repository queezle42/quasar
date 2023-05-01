{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Quasar.Network.Runtime.Generic (
  GNetworkObject(..),
) where

import Data.Bifunctor (bimap)
import Data.Binary
import Data.ByteString.Lazy qualified as BSL
import Data.Void (absurd)
import GHC.Generics
import Quasar.Network.Channel
import Quasar.Network.Multiplexer
import Quasar.Network.Runtime.Class
import Quasar.Prelude

-- * Generic

voidHandler :: RawChannelHandler
voidHandler = rawChannelHandler @(Channel () Void Void) (\_ -> absurd)

instance (Generic a, GNetworkObject (Rep a)) => IsNetworkStrategy Generic a where
  provideObject x = gProvideObject (from x)
  receiveObject = bimap to (fmap4 to) <<$>> gReceiveObject

class GNetworkObject (t :: Type -> Type) where
  gProvideObject ::
    t a ->
    Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler))
  gReceiveObject ::
    BSL.ByteString ->
    Either ParseException (Either (t a) (RawChannel -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (RawChannelHandler, t a)))

-- Datatype
instance GNetworkObject f => GNetworkObject (D1 c f) where
  gProvideObject = gProvideObject . unM1
  gReceiveObject = bimap M1 (fmap4 M1) <<$>> gReceiveObject

-- Single ctor datatype
instance GNetworkObjectParts f => GNetworkObject (C1 c f) where
  gProvideObject (M1 x) = Right \_channel context -> ("", voidHandler) <$ gProvidePart x context
  gReceiveObject "" = Right $ Right \_channel context -> (voidHandler,) <$> gReceivePart context
  gReceiveObject _cdata = Left (ParseException "Did not expect cdata (object has a single constructor)")

-- Multiple ctors
instance GNetworkConstructor (a :+: b) => GNetworkObject (a :+: b) where
  gProvideObject = gProvideConstructor 0
  gReceiveObject cdata = case decodeOrFail cdata of
    Left (_, _, msg) -> Left (ParseException msg)
    Right (_, _, cid) -> gReceiveConstructor cid


class GNetworkConstructor t where
  gProvideConstructor ::
    Word32 ->
    t a ->
    Either BSL.ByteString (RawChannel -> SendMessageContext -> STMc NoRetry '[] (BSL.ByteString, RawChannelHandler))
  gReceiveConstructor ::
    Word32 ->
    Either ParseException (Either (t a) (RawChannel -> ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (RawChannelHandler, t a)))

-- Multiple ctors
instance (GNetworkObjectParts a, GNetworkConstructor b) => GNetworkConstructor (a :+: b) where
  gProvideConstructor cid (L1 x) = Right \_channel context -> (encode cid, voidHandler) <$ gProvidePart x context
  gProvideConstructor cid (R1 x) = gProvideConstructor (cid + 1) x
  gReceiveConstructor 0 = Right $ Right \_channel context -> (voidHandler,) . L1 <$> gReceivePart context
  gReceiveConstructor cid = bimap R1 (fmap4 R1) <$> gReceiveConstructor @b (cid - 1)

-- Last ctor
instance GNetworkObjectParts f => GNetworkConstructor (C1 c f) where
  gProvideConstructor cid x = Right \_channel context -> (encode cid, voidHandler) <$ gProvidePart x context
  gReceiveConstructor 0 = Right $ Right \_channel context -> (voidHandler,) . M1 <$> gReceivePart context
  gReceiveConstructor _ = Left (ParseException "Invalid constructor id")


class GNetworkObjectParts t where
  gProvidePart :: t a -> SendMessageContext -> STMc NoRetry '[] ()
  gReceivePart :: ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (t a)

-- Drop metadata
instance GNetworkObjectParts f => GNetworkObjectParts (M1 i c f) where
  gProvidePart (M1 x) = gProvidePart x
  gReceivePart = M1 <<$>> gReceivePart

-- No fields
instance GNetworkObjectParts U1 where
  gProvidePart U1 _context = pure ()
  gReceivePart _context = pure U1

instance (GNetworkObjectParts a, GNetworkObjectParts b) => GNetworkObjectParts (a :*: b) where
  gProvidePart (x :*: y) context = do
    gProvidePart x context
    gProvidePart y context
  gReceivePart context = do
    x <- gReceivePart context
    y <- gReceivePart context
    pure (x :*: y)

instance NetworkObject a => GNetworkObjectParts (Rec0 a) where
  gProvidePart x context = provideObjectAsMessagePart context (unK1 x)
  gReceivePart = K1 <<$>> receiveObjectFromMessagePart


-- * NetworkObject instances based on Generic

instance (NetworkObject a, NetworkObject b) => NetworkObject (a, b) where
  type NetworkStrategy (a, b) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c) => NetworkObject (a, b, c) where
  type NetworkStrategy (a, b, c) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d) => NetworkObject (a, b, c, d) where
  type NetworkStrategy (a, b, c, d) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e) => NetworkObject (a, b, c, d, e) where
  type NetworkStrategy (a, b, c, d, e) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e, NetworkObject f) => NetworkObject (a, b, c, d, e, f) where
  type NetworkStrategy (a, b, c, d, e, f) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e, NetworkObject f, NetworkObject g) => NetworkObject (a, b, c, d, e, f, g) where
  type NetworkStrategy (a, b, c, d, e, f, g) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e, NetworkObject f, NetworkObject g, NetworkObject h) => NetworkObject (a, b, c, d, e, f, g, h) where
  type NetworkStrategy (a, b, c, d, e, f, g, h) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e, NetworkObject f, NetworkObject g, NetworkObject h, NetworkObject i) => NetworkObject (a, b, c, d, e, f, g, h, i) where
  type NetworkStrategy (a, b, c, d, e, f, g, h, i) = Generic

instance (NetworkObject a, NetworkObject b, NetworkObject c, NetworkObject d, NetworkObject e, NetworkObject f, NetworkObject g, NetworkObject h, NetworkObject i, NetworkObject j) => NetworkObject (a, b, c, d, e, f, g, h, i, j) where
  type NetworkStrategy (a, b, c, d, e, f, g, h, i, j) = Generic
