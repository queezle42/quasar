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

instance (Generic a, GNetworkObject (Rep a)) => IsNetworkStrategy Generic a where
  provideObject x = fmap (const . fmap2 (,voidHandler)) (gProvideObject (from x))
  receiveObject = bimap to (const . fmap2 ((voidHandler,) . to)) <<$>> gReceiveObject

voidHandler :: RawChannelHandler
voidHandler = rawChannelHandler @(Channel () Void Void) (\_ -> absurd)

class GNetworkObject (t :: Type -> Type) where
  gProvideObject ::
    t a ->
    Either BSL.ByteString (SendMessageContext -> STMc NoRetry '[] BSL.ByteString)
  gReceiveObject ::
    BSL.ByteString ->
    Either ParseException (Either (t a) (ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (t a)))

-- Datatype
instance GNetworkObject f => GNetworkObject (D1 c f) where
  gProvideObject = gProvideObject . unM1
  gReceiveObject = bimap M1 (fmap2 M1) <<$>> gReceiveObject

-- Single ctor datatype
instance GNetworkObjectContent f => GNetworkObject (C1 c f) where
  gProvideObject (M1 x) = maybeToEither "" $ fmap3 (\() -> "") (gProvideContent x)
  gReceiveObject "" = Right $ bimap M1 (fmap2 M1) gReceiveContent
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
    Either BSL.ByteString (SendMessageContext -> STMc NoRetry '[] BSL.ByteString)
  gReceiveConstructor ::
    Word32 ->
    Either ParseException (Either (t a) (ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (t a)))

-- Seek ctor
instance (GNetworkConstructor a, GNetworkConstructor b) => GNetworkConstructor (a :+: b) where
  gProvideConstructor cid (L1 x) = gProvideConstructor cid x
  gProvideConstructor cid (R1 x) = gProvideConstructor (cid + 1) x
  gReceiveConstructor 0 = bimap L1 (fmap2 L1) <$> gReceiveConstructor 0
  gReceiveConstructor cid = bimap R1 (fmap2 R1) <$> gReceiveConstructor @b (cid - 1)

-- Selected ctor
instance GNetworkObjectContent f => GNetworkConstructor (C1 c f) where
  gProvideConstructor cid (M1 x) = maybeToEither "" $ fmap3 (\() -> encode cid) (gProvideContent x)
  gReceiveConstructor 0 = Right $ bimap M1 (fmap2 M1) gReceiveContent
  gReceiveConstructor _ = Left (ParseException "Invalid constructor id")


class GNetworkObjectContent t where
  gProvideContent :: t a -> Maybe (SendMessageContext -> STMc NoRetry '[] ())
  gReceiveContent :: Either (t a) (ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (t a))

-- No fields
instance GNetworkObjectContent U1 where
  gProvideContent U1 = Nothing
  gReceiveContent = Left U1

-- One field
instance GNetworkObjectParts (S1 c f) => GNetworkObjectContent (S1 c f) where
  gProvideContent = Just . gProvidePart
  gReceiveContent = Right gReceivePart

-- Multiple fields
instance GNetworkObjectParts (a :*: b) => GNetworkObjectContent (a :*: b) where
  gProvideContent = Just . gProvidePart
  gReceiveContent = Right gReceivePart


class GNetworkObjectParts t where
  gProvidePart :: t a -> SendMessageContext -> STMc NoRetry '[] ()
  gReceivePart :: ReceiveMessageContext -> STMc NoRetry '[MultiplexerException] (t a)

instance (GNetworkObjectParts a, GNetworkObjectParts b) => GNetworkObjectParts (a :*: b) where
  gProvidePart (x :*: y) context = do
    gProvidePart x context
    gProvidePart y context
  gReceivePart context = do
    x <- gReceivePart context
    y <- gReceivePart context
    pure (x :*: y)

instance NetworkObject a => GNetworkObjectParts (S1 c (Rec0 a)) where
  gProvidePart (M1 (K1 x)) context = provideObjectAsMessagePart context x
  gReceivePart = M1 . K1 <<$>> receiveObjectFromMessagePart


-- * NetworkObject instances based on Generic

instance NetworkObject () where
  type NetworkStrategy () = Generic

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
