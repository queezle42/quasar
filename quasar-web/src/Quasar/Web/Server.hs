module Quasar.Web.Server (
  toWaiApplication,
) where

import Control.Monad.Catch
import Data.Aeson
import Data.Binary.Builder qualified as Binary
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)
import Quasar
import Quasar.Observable.AccumulatingObserver
import Quasar.Observable.Core
import Quasar.Observable.List (ObservableList, ListDelta(..), ListDeltaOperation(..))
import Quasar.Observable.List qualified as ObservableList
import Quasar.Observable.Traversable
import Quasar.Prelude
import Quasar.Utils.Fix (mfixTVar)
import Quasar.Web
import System.IO (stderr)


toWaiApplication :: DomNode -> Wai.Application
toWaiApplication rootNode = Wai.websocketsOr webSocketsOptions (toWebSocketsApp rootNode) waiApp
  where
    webSocketsOptions =
      WebSockets.defaultConnectionOptions {
        WebSockets.connectionStrictUnicode = True
      }

toWebSocketsApp :: DomNode -> WebSockets.ServerApp
toWebSocketsApp rootNode pendingConnection = do
  connection <- WebSockets.acceptRequestWith pendingConnection acceptRequestConfig
  nextJsRef <- newTVarIO 0
  let client = Client { nextJsRef }
  handleAll (\ex -> logError (displayException ex)) do
    runQuasarCombineExceptions do
      x <- async $ receiveThread client connection
      y <- async $ sendThread client rootNode connection
      void $ await x <> await y
  where
    acceptRequestConfig :: WebSockets.AcceptRequest
    acceptRequestConfig =
      WebSockets.defaultAcceptRequest {
        WebSockets.acceptSubprotocol = Just "quasar-web-dev"
      }

newtype Client = Client {
  nextJsRef :: TVar JsRef
}

newJsRef :: Client -> STMc NoRetry '[] JsRef
newJsRef client = do
  stateTVar client.nextJsRef \i -> (i, i + 1)

receiveThread :: Client -> WebSockets.Connection -> QuasarIO ()
receiveThread client connection = liftIO do
  handleWebsocketException connection $ forever do
      WebSockets.receiveDataMessage connection >>= \case
        WebSockets.Binary _ -> WebSockets.sendCloseCode connection 1002 ("Client must not send binary data." :: BS.ByteString)
        WebSockets.Text msg _ -> messageHandler connection msg

sendThread :: Client -> DomNode -> WebSockets.Connection -> QuasarIO ()
sendThread client rootNode connection = do
  traceIO "[quasar-web] new client"
  (wireNode, splice) <- atomically $ liftSTMc $ newDomNodeSplice client rootNode
  let initialMessage = [SetRoot wireNode]
  liftIO $ WebSockets.sendTextData connection (encode initialMessage)
  handleAll (\ex -> atomicallyC (freeSplice splice) >> throwM ex) do
    forever do
      updates <- atomically $ do
        updates <- liftSTMc $ generateSpliceCommands splice
        check (not (null updates))
        pure updates
      liftIO $ WebSockets.sendTextData connection (encode updates)


handleWebsocketException :: WebSockets.Connection -> IO () -> IO ()
handleWebsocketException connection =
  handle \case
    WebSockets.CloseRequest _ _ -> pure ()
    WebSockets.ConnectionClosed -> pure ()
    WebSockets.ParseException _ -> WebSockets.sendCloseCode connection 1001 ("WebSocket communication error." :: BS.ByteString)
    WebSockets.UnicodeException _ -> WebSockets.sendCloseCode connection 1001 ("Client sent invalid UTF-8." :: BS.ByteString)

messageHandler :: WebSockets.Connection -> BSL.ByteString -> IO ()
messageHandler connection "ping" = WebSockets.sendTextData connection (encode [Pong])
messageHandler _ msg = BSL.hPutStr stderr $ "Unhandled message: " <> msg <> "\n"


type JsRef = Word64

data Command
  = SetRoot WireNode
  | SetTextNode JsRef Text
  | InsertChild JsRef Int WireNode
  | AppendChild JsRef WireNode
  | RemoveChild JsRef Int
  | RemoveAllChildren JsRef
  | FreeRef JsRef
  | Pong
  deriving Show

data WireNode
  = WireNodeElement WireElement
  | WireNodeTextNode WireText
  deriving Show

data WireElement = WireElement {
  ref :: Maybe JsRef,
  tag :: Text,
  attributes :: Map Text (Maybe Text),
  children :: [WireNode]
}
  deriving Show

data WireText = WireText (Maybe JsRef) Text
  deriving Show

instance ToJSON Command where
  toJSON (SetRoot wire) =
    object ["fn" .= ("root" :: Text), "node" .= wire]
  toJSON (SetTextNode ref text) =
    object ["fn" .= ("text" :: Text), "ref" .= ref, "text" .= text]
  toJSON (InsertChild ref index node) =
    object ["fn" .= ("insert" :: Text), "ref" .= ref, "i" .= index, "node" .= node]
  toJSON (AppendChild ref element) =
    object ["fn" .= ("append" :: Text), "ref" .= ref, "node" .= element]
  toJSON (RemoveChild ref index) =
    object ["fn" .= ("remove" :: Text), "ref" .= ref, "i" .= index]
  toJSON (RemoveAllChildren ref) =
    object ["fn" .= ("removeAll" :: Text), "ref" .= ref]
  toJSON (FreeRef ref) =
    object ["fn" .= ("free" :: Text), "ref" .= ref]
  toJSON Pong =
    object ["fn" .= ("pong" :: Text)]

  toEncoding (SetRoot wire) =
    pairs ("fn" .= ("root" :: Text) <> "node" .= wire)
  toEncoding (SetTextNode ref text) =
    pairs ("fn" .= ("text" :: Text) <> "ref" .= ref <> "text" .= text)
  toEncoding (InsertChild ref index element) =
    pairs ("fn" .= ("insert" :: Text) <> "ref" .= ref <> "i" .= index <> "node" .= element)
  toEncoding (AppendChild ref element) =
    pairs ("fn" .= ("append" :: Text) <> "ref" .= ref <> "node" .= element)
  toEncoding (RemoveChild ref index) =
    pairs ("fn" .= ("remove" :: Text) <> "ref" .= ref <> "i" .= index)
  toEncoding (RemoveAllChildren ref) =
    pairs ("fn" .= ("removeAll" :: Text) <> "id" .= ref)
  toEncoding (FreeRef ref) =
    pairs ("fn" .= ("free" :: Text) <> "ref" .= ref)
  toEncoding Pong =
    pairs ("fn" .= ("pong" :: Text))

instance ToJSON WireNode where
  toJSON (WireNodeElement (WireElement ref tag attributes children)) =
    object ["type" .= ("element" :: Text), "ref" .= ref, "tag" .= tag, "attributes" .= attributes, "children" .= children]
  toJSON (WireNodeTextNode (WireText ref text)) =
    object ["type" .= ("text" :: Text), "ref" .= ref, "text" .= text]

  toEncoding (WireNodeElement (WireElement ref tag attributes children)) =
    pairs ("type" .= ("element" :: Text) <> "ref" .= ref <> "tag" .= tag <> "attributes" .= attributes <> "children" .= children)
  toEncoding (WireNodeTextNode (WireText ref text)) =
    pairs ("type" .= ("text" :: Text) <> "ref" .= ref <> "text" .= text)


class IsSplice a where
  freeSplice :: a -> STMc NoRetry '[] [JsRef]
  generateSpliceCommands :: a -> STMc NoRetry '[] [Command]

instance IsSplice a => IsSplice [a] where
  freeSplice xs = fold <$> mapM freeSplice xs
  generateSpliceCommands xs = fold <$> mapM generateSpliceCommands xs

freeSpliceAsCommands :: IsSplice a => a -> STMc NoRetry '[] [Command]
freeSpliceAsCommands x = FreeRef <<$>> freeSplice x

data Splice = forall a. IsSplice a => Splice a

instance IsSplice Splice where
  freeSplice (Splice x) = freeSplice x
  generateSpliceCommands (Splice x) = generateSpliceCommands x


newDomNodeSplice :: Client -> DomNode -> STMc NoRetry '[] (WireNode, [Splice])
newDomNodeSplice client (DomNodeElement element) = newElementSplice client element
newDomNodeSplice client (DomNodeTextNode text) = newTextNodeSplice client text


newtype ElementSplice = ElementSplice (TVar (Maybe (JsRef, [Splice])))

instance IsSplice ElementSplice where
  freeSplice (ElementSplice var) = do
    readTVar var >>= \case
      Nothing -> pure []
      Just (ref, splices) -> do
        writeTVar var Nothing
        childRefs <- fold <$> mapM freeSplice splices
        pure (ref : childRefs)

  generateSpliceCommands (ElementSplice var) = do
    readTVar var >>= \case
      Nothing -> pure []
      Just (_ref, splices) -> do
        fold <$> mapM generateSpliceCommands splices

newElementSplice :: Client -> DomElement -> STMc NoRetry '[] (WireNode, [Splice])
newElementSplice client element = do
  ref <- newJsRef client

  (children, contentSplice) <- newChildrenSplice client ref element.children

  let wireElement = WireElement {
      ref = Just ref,
      tag = element.tagName,
      attributes = mempty,
      children
    }

  var <- newTVar (Just (ref, contentSplice))

  pure (WireNodeElement wireElement, [Splice (ElementSplice var)])


newtype TextSplice = TextSplice (TVar (Maybe (TSimpleDisposer, JsRef, TVar (Maybe Text))))

instance IsSplice TextSplice where
  freeSplice (TextSplice var) = do
    readTVar var >>= \case
      Nothing -> pure []
      Just (disposer, ref, _) -> do
        writeTVar var Nothing
        disposeTSimpleDisposer disposer
        pure [ref]

  generateSpliceCommands (TextSplice var) = do
    readTVar var >>= \case
      Nothing -> pure []
      Just (_disposer, ref, outbox) -> do
        readTVar outbox >>= \case
          Nothing -> pure []
          Just newText -> do
            writeTVar outbox Nothing
            pure [SetTextNode ref newText]

newTextNodeSplice :: Client -> DomTextNode -> STMc NoRetry '[] (WireNode, [Splice])
newTextNodeSplice client (DomTextNode textObservable) = do
  updateVar <- newTVar Nothing
  (disposer, initial) <- attachSimpleObserver textObservable (writeTVar updateVar . Just)

  if isTrivialTSimpleDisposer disposer
    then pure (WireNodeTextNode (WireText Nothing initial), [])
    else do
      ref <- newJsRef client
      var <- newTVar (Just (disposer, ref, updateVar))
      pure (WireNodeTextNode (WireText (Just ref) initial), [Splice (TextSplice var)])


data AttributeMapSplice = AttributeMapSplice

data AttributeSplice

--newAttributeMapSplice :: Client -> JsRef -> ObservableMap NoLoad '[] Text (Maybe Text) -> STMc NoRetry '[] ([WireAttribute], Splice)
--newAttributeMapSplice = undefined


data ChildrenSplice =
  ChildrenSplice
    Client
    JsRef
    (AccumulatingObserver NoLoad '[] Seq DomNode)
    (TVar (Maybe (ObserverState NoLoad (ObservableResult '[] Seq) [Splice])))

instance IsSplice ChildrenSplice where
  freeSplice (ChildrenSplice _ _ accum var) = do
    disposeAccumulatingObserver accum
    readTVar var >>= \case
      Nothing -> pure []
      Just state -> do
        writeTVar var Nothing
        fold <$> mapM freeSplice (toList state)

  generateSpliceCommands (ChildrenSplice client ref accum var) = do
    containerCommands <- takeAccumulatingObserver accum Live >>= \case
      Nothing -> pure []
      Just change -> do
        readTVar var >>= \case
          Nothing -> pure []
          Just state -> do

            let ctx = state.context
            case validateChange ctx change of
              Nothing -> pure []
              Just validatedChange -> do
                validatedWireAndSpliceChange <- traverse (newDomNodeSplice client) validatedChange
                let wireAndSpliceChange = validatedWireAndSpliceChange.unvalidated
                let wireChange = fst <$> wireAndSpliceChange
                let spliceChange = snd <$> wireAndSpliceChange

                let removedSplices = fold (selectRemovedByChange change state)
                freeCommands <- fold <$> mapM freeSpliceAsCommands removedSplices

                forM_ (applyObservableChange spliceChange state)
                  \(_, newState) -> writeTVar var (Just newState)

                pure (freeCommands <> listChangeCommands ref ctx wireChange)

    childCommands <- readTVar var >>= \case
      Nothing -> pure []
      Just state -> fold <$> mapM generateSpliceCommands (toList state)

    pure (containerCommands <> childCommands)

newChildrenSplice :: Client -> JsRef -> ObservableList NoLoad '[] DomNode -> STMc NoRetry '[] ([WireNode], [Splice])
newChildrenSplice client ref childrenObservable = do
  (maccum, initial) <- attachAccumulatingObserver (toObservableT childrenObservable)

  let ObservableStateLive (ObservableResultTrivial nodes) = initial
  (initialWireNodes, splices) <- Seq.unzip <$> mapM (newDomNodeSplice client) nodes

  case maccum of
    Nothing -> pure (toList initialWireNodes, fold splices)
    Just accum -> do
      var <- newTVar (Just (ObserverStateLive (ObservableResultOk splices)))
      pure (toList initialWireNodes, [Splice (ChildrenSplice client ref accum var)])

listChangeCommands ::
  JsRef ->
  ObserverContext NoLoad (ObservableResult '[] Seq) ->
  ObservableChange NoLoad (ObservableResult '[] Seq) WireNode ->
  [Command]
listChangeCommands ref _ctx (ObservableChangeLiveReplace (ObservableResultTrivial xs)) =
  RemoveAllChildren ref : fmap (AppendChild ref) (toList xs)
listChangeCommands ref ctx (ObservableChangeLiveDelta (ListDelta deltaOps)) =
  go 0 initialListLength deltaOps
  where
    initialListLength = case ctx of
      (ObserverContextLive (Just len)) -> len
      (ObserverContextLive Nothing) -> 0
    go :: ObservableList.Length -> ObservableList.Length -> [ListDeltaOperation WireNode] -> [Command]
    go _offset ((<= 0) -> True) [] = []
    go offset remaining [] = RemoveChild ref (fromIntegral offset) : go (offset + 1) (remaining -1) []
    go offset remaining (ListKeep n : ops) = go (offset + n) (remaining - n) ops
    go offset remaining (ListDrop i : ops) = replicate (fromIntegral i) (RemoveChild ref (fromIntegral offset)) <> go offset (remaining - i) ops
    go offset 0 (ListSplice xs : ops) = (AppendChild ref <$> toList xs) <> go (offset + fromIntegral (Seq.length xs)) 0 ops
    go offset remaining (ListSplice Seq.Empty : ops) = go offset remaining ops
    go offset remaining (ListSplice (x :<| xs) : ops) = InsertChild ref (fromIntegral offset) x : go (offset + 1) remaining (ListSplice xs : ops)


-- * Wai

waiApp :: Wai.Application
waiApp req respond =
  if Wai.requestMethod req == HTTP.methodGet
    then respond =<< servePath (Wai.pathInfo req)
    else respond methodNotAllowed
  where
    servePath :: [Text] -> IO Wai.Response
    servePath [] = pure waiIndex
    servePath ("quasar-web-client":path) = do
      let dataFile = intercalate "/" ("quasar-web-client":(Text.unpack <$> path))
      filePath <- getDataFileName dataFile
      let headers = contentType (List.last path)
      pure $ Wai.responseFile HTTP.status200 headers filePath Nothing
    servePath _ = pure notFound

waiIndex :: Wai.Response
waiIndex = Wai.responseBuilder HTTP.status200 [htmlContentType] indexHtml
  where
    indexHtml :: Binary.Builder
    indexHtml = mconcat [
      Binary.fromByteString "<!DOCTYPE html>\n",
      Binary.fromByteString "<script type=module>import { initializeQuasarWebClient } from './quasar-web-client/main.js'; initializeQuasarWebClient();</script>",
      Binary.fromByteString "<meta charset=utf-8 />",
      Binary.fromByteString "<meta name=viewport content=\"width=device-width, initial-scale=1.0\" />",
      Binary.fromByteString "<title>quasar</title>",
      Binary.fromByteString "<div id=quasar-web-state></div>",
      Binary.fromByteString "<div id=quasar-web-root></div>"
      ]


-- ** Utils

-- *** Content types

contentType :: Text -> [HTTP.Header]
contentType file
  | Text.isSuffixOf ".js" file = [javascriptContentType]
  | Text.isSuffixOf ".css" file = [cssContentType]
  | Text.isSuffixOf ".html" file = [htmlContentType]
  | otherwise = []

-- | HTTP header for the "text/plain" content type.
textContentType :: HTTP.Header
textContentType = ("Content-Type", "text/plain; charset=utf-8")

-- | HTTP header for the "text/html" content type.
htmlContentType :: HTTP.Header
htmlContentType = ("Content-Type", "text/html; charset=utf-8")

-- | HTTP header for the "application/javascript" content type.
javascriptContentType :: HTTP.Header
javascriptContentType = ("Content-Type", "application/javascript; charset=utf-8")

-- | HTTP header for the "text/css" content type.
cssContentType :: HTTP.Header
cssContentType = ("Content-Type", "text/css; charset=utf-8")


-- *** HTTP error pages

-- | Builds an error page from an http status code and a message.
buildError :: HTTP.Status -> BS.ByteString -> Wai.Response
buildError status message = Wai.responseBuilder status [textContentType] (Binary.fromByteString message)

-- | A 404 "Not Found" error page.
notFound :: Wai.Response
notFound = buildError HTTP.notFound404 "404 Not Found"

-- | A 405 "Method Not Allowed" error page.
methodNotAllowed :: Wai.Response
methodNotAllowed = buildError HTTP.methodNotAllowed405 "405 Method Not Allowed"
