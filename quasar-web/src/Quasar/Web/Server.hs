module Quasar.Web.Server (
  waiApplication,
) where

import Control.Monad.Catch
import Data.Aeson
import Data.Binary.Builder qualified as Binary
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List qualified as List
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
import Quasar.Prelude
import Quasar.Timer
import Quasar.Utils.Fix (mfixExtra)
import Quasar.Web
import System.IO (stderr)


type RawHtml = Builder


waiApplication :: WebUi -> Wai.Application
waiApplication webUi = Wai.websocketsOr webSocketsOptions (webSocketsApp webUi) waiApp
  where
    webSocketsOptions =
      WebSockets.defaultConnectionOptions {
        WebSockets.connectionStrictUnicode = True
      }

webSocketsApp :: WebUi -> WebSockets.ServerApp
webSocketsApp webUi pendingConnection = do
  connection <- WebSockets.acceptRequestWith pendingConnection acceptRequestConfig
  handleAll (\ex -> logError (displayException ex)) do
    runQuasarCombineExceptions do
      x <- async $ receiveThread connection
      y <- async $ sendThread webUi connection
      void $ await x <> await y
  where
    acceptRequestConfig :: WebSockets.AcceptRequest
    acceptRequestConfig =
      WebSockets.defaultAcceptRequest {
        WebSockets.acceptSubprotocol = Just "quasar-web-v1"
      }

receiveThread :: WebSockets.Connection -> QuasarIO ()
receiveThread connection = liftIO do
  handleWebsocketException connection $ forever do
      WebSockets.receiveDataMessage connection >>= \case
        WebSockets.Binary _ -> WebSockets.sendCloseCode connection 1002 ("Client must not send binary data." :: BS.ByteString)
        WebSockets.Text msg _ -> messageHandler connection msg

sendThread :: WebUi -> WebSockets.Connection -> QuasarIO ()
sendThread webUi connection = do
  client <- Client <$> newTVarIO 0
  traceIO "new client"
  (initialHtml, generateUpdateFn, disposer) <- atomically $ liftSTMc $ foobar client webUi
  -- let initialMessage = TL.encodeUtf8 (Builder.toLazyText ("set quasar-web-root\n" <> initialHtml))
  let initialMessage = [UpdateRoot initialHtml]
  traceIO $ "sending " <> show initialMessage
  liftIO $ WebSockets.sendTextData connection (encode initialMessage)
  handleAll (\ex -> dispose disposer >> throwM ex) do
    forever do
      updates <- atomicallyC $ do
        updates <- liftSTMc generateUpdateFn
        check (not (null updates))
        pure updates
      traceIO $ "sending " <> show updates
      liftIO $ WebSockets.sendTextData connection (encode updates)

      -- Waiting should be irrelevant since updates are merged
      -- This is a test to see if that works (TODO remove)
      await =<< newDelay 4_000_000


type SpliceId = Word64
data Client = Client (TVar SpliceId)
data ClientSplice = ClientSplice Client SpliceId (TVar (Either WebUi (GenerateClientUpdate, TSimpleDisposer)))

type GenerateClientUpdate = STMc NoRetry '[] [Command]
data Command
  = UpdateRoot RawHtml
  | UpdateSplice SpliceId RawHtml
  deriving Show

instance ToJSON Command where
    toJSON (UpdateRoot html) =
        object ["fn" .= ("root" :: Text), "html" .= Builder.toLazyText html]
    toJSON (UpdateSplice spliceId html) =
        object ["fn" .= ("splice" :: Text), "id" .= spliceId, "html" .= Builder.toLazyText html]

    toEncoding (UpdateRoot html) =
        pairs ("fn" .= ("root" :: Text) <> "html" .= Builder.toLazyText html)
    toEncoding (UpdateSplice spliceId html) =
        pairs ("fn" .= ("splice" :: Text) <> "id" .= spliceId <> "html" .= Builder.toLazyText html)

nextSpliceId :: Client -> STMc NoRetry '[] SpliceId
nextSpliceId (Client nextSpliceIdVar) = stateTVar nextSpliceIdVar \i -> (i, i + 1)

newClientSplice :: Client -> WebUi -> STMc NoRetry '[] (RawHtml, ClientSplice, TSimpleDisposer)
newClientSplice client content = do
  spliceId <- nextSpliceId client
  (contentHtml, generateContentUpdates, contentDisposer) <- foobar client content
  stateVar <- newTVar (Right (generateContentUpdates, contentDisposer))
  let clientSplice = ClientSplice client spliceId stateVar
  disposer <- newUnmanagedTSimpleDisposer (disposeClientSplice clientSplice)
  let html = mconcat ["<quasar-splice id=quasar-splice-", Builder.fromString (show spliceId), ">", contentHtml, "</quasar-splice>"]
  pure (html, clientSplice, disposer)

disposeClientSplice :: ClientSplice -> STMc NoRetry '[] ()
disposeClientSplice (ClientSplice _ _ stateVar) = do
  swapTVar stateVar (Right mempty) >>= \case
    Left _ -> pure ()
    Right (_, disposer) -> disposeTSimpleDisposer disposer

replaceSpliceContent :: ClientSplice -> WebUi -> STMc NoRetry '[] ()
replaceSpliceContent (ClientSplice _ _ stateVar) webUi = do
  swapTVar stateVar (Left webUi) >>= \case
    Left _ -> pure ()
    Right (_, disposer) -> disposeTSimpleDisposer disposer

generateSpliceUpdate :: ClientSplice -> GenerateClientUpdate
generateSpliceUpdate (ClientSplice client spliceId stateVar) = do
  readTVar stateVar >>= \case
    Left webUi -> do
      (html, newUpdateFn, disposer) <- foobar client webUi
      writeTVar stateVar (Right (newUpdateFn, disposer))
      pure [UpdateSplice spliceId html]
    Right (generateContentUpdatesFn, _) -> generateContentUpdatesFn

foobar :: Client -> WebUi -> STMc NoRetry '[] (RawHtml, GenerateClientUpdate, TSimpleDisposer)
foobar client (WebUiObservable observable) =
  mfixExtra \splice -> do
    (disposer, initial) <- attachObserver observable (replaceSpliceContent splice)
    (html, splice', spliceDisposer) <- newClientSplice client initial
    let result = (html, generateSpliceUpdate splice', disposer <> spliceDisposer)
    pure (result, splice')
foobar _ (WebUiHtmlElement (HtmlElement html)) = pure (Builder.fromLazyText html, pure [], mempty)
foobar client (WebUiConcat webUis) = mconcat <$> mapM (foobar client) webUis
foobar _ _ = error "not implemented"

handleWebsocketException :: WebSockets.Connection -> IO () -> IO ()
handleWebsocketException connection =
  handle \case
    WebSockets.CloseRequest _ _ -> pure ()
    WebSockets.ConnectionClosed -> pure ()
    WebSockets.ParseException _ -> WebSockets.sendCloseCode connection 1001 ("WebSocket communication error." :: BS.ByteString)
    WebSockets.UnicodeException _ -> WebSockets.sendCloseCode connection 1001 ("Client sent invalid UTF-8." :: BS.ByteString)

messageHandler :: WebSockets.Connection -> BSL.ByteString -> IO ()
messageHandler connection "ping" = WebSockets.sendTextData connection ("pong" :: BS.ByteString)
messageHandler _ msg = BSL.hPutStr stderr $ "Unhandled message: " <> msg <> "\n"

waiApp :: Wai.Application
waiApp req respond =
  if Wai.requestMethod req == HTTP.methodGet
    then respond =<< servePath (Wai.pathInfo req)
    else respond methodNotAllowed
  where
    servePath :: [Text] -> IO Wai.Response
    servePath [] = pure index
    servePath ("quasar-web-client":path) = do
      let dataFile = intercalate "/" ("quasar-web-client":(Text.unpack <$> path))
      filePath <- getDataFileName dataFile
      let headers = contentType (List.last path)
      pure $ Wai.responseFile HTTP.status200 headers filePath Nothing
    servePath _ = pure notFound

index :: Wai.Response
index = (Wai.responseBuilder HTTP.status200 [htmlContentType] indexHtml)
  where
    indexHtml :: Binary.Builder
    indexHtml = mconcat [
      Binary.fromByteString "<!DOCTYPE html>\n",
      Binary.fromByteString "<script type=module>import { initializeQuasarWebClient } from './quasar-web-client/main.js'; initializeQuasarWebClient();</script>",
      Binary.fromByteString "<meta charset=utf-8 />",
      Binary.fromByteString "<meta name=viewport content=\"width=device-width, initial-scale=1.0\" />",
      Binary.fromByteString "<title>quasar</title>",
      Binary.fromByteString "<div id=app></div>"
      ]


-- * Utils

-- ** Content types

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


-- ** HTTP error pages

-- | Builds an error page from an http status code and a message.
buildError :: HTTP.Status -> BS.ByteString -> Wai.Response
buildError status message = Wai.responseBuilder status [textContentType] (Binary.fromByteString message)

-- | A 404 "Not Found" error page.
notFound :: Wai.Response
notFound = buildError HTTP.notFound404 "404 Not Found"

-- | A 405 "Method Not Allowed" error page.
methodNotAllowed :: Wai.Response
methodNotAllowed = buildError HTTP.methodNotAllowed405 "405 Method Not Allowed"
