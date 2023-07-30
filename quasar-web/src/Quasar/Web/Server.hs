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
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy.Builder (Builder)
import Data.Text.Lazy.Builder qualified as Builder
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)
import Quasar
import Quasar.Observable.ObservableList (ObservableList, ObservableListDelta(..), ObservableListOperation(..))
import Quasar.Observable.ObservableList qualified as ObservableList
import Quasar.Prelude
import Quasar.Utils.Fix (mfixExtra)
import Quasar.Web
import System.IO (stderr)


type RawHtml = Builder


toWaiApplication :: DomElement -> Wai.Application
toWaiApplication rootElement = Wai.websocketsOr webSocketsOptions (toWebSocketsApp rootElement) waiApp
  where
    webSocketsOptions =
      WebSockets.defaultConnectionOptions {
        WebSockets.connectionStrictUnicode = True
      }

toWebSocketsApp :: DomElement -> WebSockets.ServerApp
toWebSocketsApp rootElement pendingConnection = do
  connection <- WebSockets.acceptRequestWith pendingConnection acceptRequestConfig
  client <- Client <$> newTVarIO 0
  handleAll (\ex -> logError (displayException ex)) do
    runQuasarCombineExceptions do
      x <- async $ receiveThread client connection
      y <- async $ sendThread client rootElement connection
      void $ await x <> await y
  where
    acceptRequestConfig :: WebSockets.AcceptRequest
    acceptRequestConfig =
      WebSockets.defaultAcceptRequest {
        WebSockets.acceptSubprotocol = Just "quasar-web-v1"
      }

newtype Client = Client {
  nextSpliceIdVar :: TVar SpliceId
}

receiveThread :: Client -> WebSockets.Connection -> QuasarIO ()
receiveThread client connection = liftIO do
  handleWebsocketException connection $ forever do
      WebSockets.receiveDataMessage connection >>= \case
        WebSockets.Binary _ -> WebSockets.sendCloseCode connection 1002 ("Client must not send binary data." :: BS.ByteString)
        WebSockets.Text msg _ -> messageHandler connection msg

sendThread :: Client -> DomElement -> WebSockets.Connection -> QuasarIO ()
sendThread client rootElement connection = do
  traceIO "[quasar-web] new client"
  (initialHtml, generateUpdateFn, disposer) <- atomically $ liftSTMc $ foobar client rootElement
  let initialMessage = [UpdateRoot initialHtml]
  liftIO $ WebSockets.sendTextData connection (encode initialMessage)
  handleAll (\ex -> dispose disposer >> throwM ex) do
    forever do
      updates <- atomically $ do
        updates <- liftSTMc generateUpdateFn
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


type SpliceId = Word64

type GenerateClientUpdate = STMc NoRetry '[] [Command]
data Command
  = UpdateRoot RawHtml
  | UpdateSplice SpliceId RawHtml
  | ListInsert SpliceId Int RawHtml
  | ListAppend SpliceId RawHtml
  | ListRemove SpliceId Int
  | ListRemoveAll SpliceId
  | Pong
  deriving Show

data WireElement = WireDomElement {
  ref :: Maybe SpliceId,
  tag :: Text,
  attributes :: Map Text (Maybe Text),
  content :: WireElementContent
}

data WireElementContent
  = WireChildren [WireElement]
  | WireInnerText Text

instance ToJSON Command where
  toJSON (UpdateRoot html) =
    object ["fn" .= ("root" :: Text), "html" .= Builder.toLazyText html]
  toJSON (UpdateSplice spliceId html) =
    object ["fn" .= ("splice" :: Text), "id" .= spliceId, "html" .= Builder.toLazyText html]
  toJSON (ListInsert listId index html) =
    object ["fn" .= ("listInsert" :: Text), "id" .= listId, "i" .= index, "html" .= Builder.toLazyText html]
  toJSON (ListAppend listId html) =
    object ["fn" .= ("listAppend" :: Text), "id" .= listId, "html" .= Builder.toLazyText html]
  toJSON (ListRemove listId index) =
    object ["fn" .= ("listRemove" :: Text), "id" .= listId, "i" .= index]
  toJSON (ListRemoveAll listId) =
    object ["fn" .= ("listRemoveAll" :: Text), "id" .= listId]
  toJSON Pong =
    object ["fn" .= ("pong" :: Text)]

  toEncoding (UpdateRoot html) =
    pairs ("fn" .= ("root" :: Text) <> "html" .= Builder.toLazyText html)
  toEncoding (UpdateSplice spliceId html) =
    pairs ("fn" .= ("splice" :: Text) <> "id" .= spliceId <> "html" .= Builder.toLazyText html)
  toEncoding (ListInsert listId index html) =
    pairs ("fn" .= ("listInsert" :: Text) <> "id" .= listId <> "i" .= index <> "html" .= Builder.toLazyText html)
  toEncoding (ListAppend listId html) =
    pairs ("fn" .= ("listAppend" :: Text) <> "id" .= listId <> "html" .= Builder.toLazyText html)
  toEncoding (ListRemove listId index) =
    pairs ("fn" .= ("listRemove" :: Text) <> "id" .= listId <> "i" .= index)
  toEncoding (ListRemoveAll listId) =
    pairs ("fn" .= ("listRemoveAll" :: Text) <> "id" .= listId)
  toEncoding Pong =
    pairs ("fn" .= ("pong" :: Text))

instance ToJSON WireElement where
  toJSON (WireDomElement ref tag attributes content) =
    object ["ref" .= ref, "tag" .= tag, "attributes" .= attributes, "content" .= toJSON content]

  toEncoding (WireDomElement ref tag attributes content) =
    pairs ("ref" .= ref <> "tag" .= tag <> "attributes" .= attributes <> "content" .= content)

instance ToJSON WireElementContent where
  toJSON (WireInnerText text) = object ["type" .= ("text" :: Text), "text" .= text]
  toJSON (WireChildren children) = object ["type" .= ("children" :: Text), "children" .= toJSON children]

  toEncoding (WireInnerText text) = pairs ("type" .= ("text" :: Text) <> "text" .= text)
  toEncoding (WireChildren children) = pairs ("type" .= ("children" :: Text) <> "children" .= children)

nextSpliceId :: Client -> STMc NoRetry '[] SpliceId
nextSpliceId (Client nextSpliceIdVar) = stateTVar nextSpliceIdVar \i -> (i, i + 1)


foobar :: Client -> DomElement -> STMc NoRetry '[] (RawHtml, GenerateClientUpdate, TSimpleDisposer)
foobar client domElement = undefined
--foobar client (WebUiObservable observable) =
--  mfixExtra \splice -> do
--    (disposer, initial) <- attachObserver observable (replaceSpliceContent splice)
--    (html, splice', spliceDisposer) <- newClientSplice client initial
--    let result = (html, generateSpliceUpdate splice', disposer <> spliceDisposer)
--    pure (result, splice')
--foobar _ (WebUiHtmlElement (HtmlElement html)) = pure (Builder.fromLazyText html, pure [], mempty)
--foobar client (WebUiConcat webUis) = mconcat <$> mapM (foobar client) webUis
--foobar client (WebUiObservableList observableList) = setupClientList client observableList
-- foobar client (WebUiButton _ _) = error "not implemented"


data ClientSplice = ClientSplice Client SpliceId (TVar (Either WebUi (GenerateClientUpdate, TSimpleDisposer)))

--newClientSplice :: Client -> WebUi -> STMc NoRetry '[] (RawHtml, ClientSplice, TSimpleDisposer)
--newClientSplice client content = do
--  spliceId <- nextSpliceId client
--  (contentHtml, generateContentUpdates, contentDisposer) <- foobar client content
--  stateVar <- newTVar (Right (generateContentUpdates, contentDisposer))
--  let clientSplice = ClientSplice client spliceId stateVar
--  disposer <- newUnmanagedTSimpleDisposer (disposeClientSplice clientSplice)
--  let html = mconcat ["<quasar-splice id=quasar-splice-", Builder.fromString (show spliceId), ">", contentHtml, "</quasar-splice>"]
--  pure (html, clientSplice, disposer)
--
--disposeClientSplice :: ClientSplice -> STMc NoRetry '[] ()
--disposeClientSplice (ClientSplice _ _ stateVar) = do
--  swapTVar stateVar (Right mempty) >>= \case
--    Left _ -> pure ()
--    Right (_, disposer) -> disposeTSimpleDisposer disposer
--
--replaceSpliceContent :: ClientSplice -> WebUi -> STMc NoRetry '[] ()
--replaceSpliceContent (ClientSplice _ _ stateVar) webUi = do
--  swapTVar stateVar (Left webUi) >>= \case
--    Left _ -> pure ()
--    Right (_, disposer) -> disposeTSimpleDisposer disposer
--
--generateSpliceUpdate :: ClientSplice -> GenerateClientUpdate
--generateSpliceUpdate (ClientSplice client spliceId stateVar) = do
--  readTVar stateVar >>= \case
--    Left webUi -> do
--      (html, newUpdateFn, disposer) <- foobar client webUi
--      writeTVar stateVar (Right (newUpdateFn, disposer))
--      pure [UpdateSplice spliceId html]
--    Right (generateContentUpdatesFn, _) -> generateContentUpdatesFn
--
--
--setupClientList :: Client -> ObservableList WebUi -> STMc NoRetry '[] (RawHtml, GenerateClientUpdate, TSimpleDisposer)
--setupClientList client observableList = do
--  listId <- nextSpliceId client
--  deltas <- newTVar (mempty :: ObservableListDelta WebUi)
--  items <- newTVar (mempty :: Seq (GenerateClientUpdate, TSimpleDisposer))
--
--  (listDisposer, initial) <- ObservableList.attachListDeltaObserver observableList \delta -> modifyTVar deltas (<> delta)
--  initialResults <- mapM (foobar client) initial
--  let (itemHtmls, initialItems) = Seq.unzipWith (\(html, update, disposer) -> (html, (update, disposer))) initialResults
--  writeTVar items initialItems
--
--  itemsDisposer <- newUnmanagedTSimpleDisposer do
--    swapTVar items mempty >>= mapM_ (disposeTSimpleDisposer . snd)
--
--  let
--    initialHtml = mconcat [
--      "<quasar-list id=quasar-list-",
--      Builder.fromString (show listId),
--      ">",
--      fold itemHtmls,
--      "</quasar-list>"]
--    update = generateClientListUpdate client listId deltas items
--    disposer = listDisposer <> itemsDisposer
--
--  pure (initialHtml, update, disposer)
--
--generateClientListUpdate :: Client -> SpliceId -> TVar (ObservableListDelta WebUi) -> TVar (Seq (GenerateClientUpdate, TSimpleDisposer)) -> STMc NoRetry '[] [Command]
--generateClientListUpdate client listId deltas items = do
--  (ObservableListDelta listOperations) <- swapTVar deltas mempty
--  deltaCommands <- forM listOperations \case
--    Insert index webUi -> do
--      itemsLength <- length <$> readTVar items
--      let clampedIndex = min (max index 0) itemsLength
--      (html, update, disposer) <- foobar client webUi
--      modifyTVar items (Seq.insertAt index (update, disposer))
--      pure if clampedIndex == itemsLength
--        then ListAppend listId html
--        else ListInsert listId index html
--    Delete index -> do
--      removed <- stateTVar items \orig ->
--        let
--          removed = Seq.lookup index orig
--          newList = Seq.deleteAt index orig
--        in (removed, newList)
--      forM_ removed \(_, disposer) -> disposeTSimpleDisposer disposer
--      pure (ListRemove listId index)
--    DeleteAll -> do
--      mapM_ (disposeTSimpleDisposer . snd) =<< swapTVar items mempty
--      pure (ListRemoveAll listId)
--
--  itemCommands <- mapM fst =<< readTVar items
--
--  pure (toList deltaCommands <> fold itemCommands)


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
