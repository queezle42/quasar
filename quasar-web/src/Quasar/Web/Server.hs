module Quasar.Web.Server (
  waiApplication,
) where

import Data.Binary.Builder (Builder)
import Data.Binary.Builder qualified as Builder
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as Text
import Control.Monad.Catch
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)
import Quasar
import Quasar.Prelude
import Quasar.Web
import Quasar.Timer
import Quasar.Utils.Fix (mfixExtra)
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
  handleAll (\ex -> logError (show ex)) do
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
  (initialHtml, rootSplice, disposer) <- atomically $ liftSTMc $ foobar client webUi
  forM_ [0..] \(i :: Int) -> do
    liftIO $ WebSockets.sendTextData connection ("set quasar-web-root\n<p>Hello World! " <> BS.pack (show i) <> "</p>" :: BS.ByteString)
    --liftIO $ WebSockets.sendTextData connection ("set quasar-web-root\n" <> html)
    await =<< newDelay 1_000_000


type SpliceId = Word64
data Client = Client (TVar SpliceId)
data ClientSplice = ClientSplice Client SpliceId (TVar (Maybe RawHtml)) (TVar [ClientSplice]) (TVar TSimpleDisposer)
--data ClientSplice = ClientSplice Client SpliceId (TVar (Either WebUi TSimpleDisposer)) (TVar [ClientSplice])

data Command = UpdateSplice

nextSpliceId :: Client -> STMc NoRetry '[] SpliceId
nextSpliceId (Client nextSpliceIdVar) = stateTVar nextSpliceIdVar \i -> (i, i + 1)

newClientSplice :: Client -> WebUi -> STMc NoRetry '[] (RawHtml, ClientSplice, TSimpleDisposer)
newClientSplice client content = do
  spliceId <- nextSpliceId client
  (contentHtml, subSplices, contentDisposer) <- foobar client content
  spliceUpdateVar <- newTVar Nothing
  subSplicesVar <- newTVar subSplices
  disposerVar <- newTVar contentDisposer
  let clientSplice = ClientSplice client spliceId spliceUpdateVar subSplicesVar disposerVar
  disposer <- newUnmanagedTSimpleDisposer (disposeClientSplice clientSplice)
  let html = mconcat ["<quasar-splice id=quasar-splice-", Builder.fromByteString (BS.pack (show spliceId)), ">", contentHtml, "</quasar-splice>"]
  pure (html, clientSplice, disposer)

disposeClientSplice :: ClientSplice -> STMc NoRetry '[] ()
disposeClientSplice (ClientSplice _ _ spliceUpdateVar subSplicesVar disposerVar) = do
  disposeTSimpleDisposer =<< readTVar disposerVar
  writeTVar spliceUpdateVar Nothing
  mapM_ disposeClientSplice =<< swapTVar subSplicesVar []

updateClientSplice :: ClientSplice -> WebUi -> STMc NoRetry '[] ()
updateClientSplice (ClientSplice client _ spliceUpdateVar subSplicesVar disposerVar) webUi = do
  disposeTSimpleDisposer =<< readTVar disposerVar
  (html, subSplices, disposer) <- foobar client webUi
  writeTVar spliceUpdateVar (Just html)
  writeTVar subSplicesVar subSplices
  writeTVar disposerVar disposer

foobar :: Client -> WebUi -> STMc NoRetry '[] (RawHtml, [ClientSplice], TSimpleDisposer)
foobar client (WebUiObservable observable) =
  mfixExtra \splice -> do
    (disposer, initial) <- attachObserver observable (updateClientSplice splice)
    (html, splice', spliceDisposer) <- newClientSplice client initial
    let result = (html, [splice], disposer <> spliceDisposer)
    pure (result, splice')
foobar _ (WebUiHtmlElement (HtmlElement html)) = pure (Builder.fromLazyByteString html, [], mempty)
foobar client (WebUiConcat webUis) = do
  (htmls, splices, disposers) <- unzip3 <$> mapM (foobar client) webUis
  pure (mconcat htmls, mconcat splices, mconcat disposers)
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
    indexHtml :: Builder.Builder
    indexHtml = mconcat [
      Builder.fromByteString "<!DOCTYPE html>\n",
      Builder.fromByteString "<script type=module>import { initializeQuasarWebClient } from './quasar-web-client/main.js'; initializeQuasarWebClient();</script>",
      Builder.fromByteString "<meta charset=utf-8 />",
      Builder.fromByteString "<meta name=viewport content=\"width=device-width, initial-scale=1.0\" />",
      Builder.fromByteString "<title>quasar</title>",
      Builder.fromByteString "<div id=app></div>"
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
buildError status message = Wai.responseBuilder status [textContentType] (Builder.fromByteString message)

-- | A 404 "Not Found" error page.
notFound :: Wai.Response
notFound = buildError HTTP.notFound404 "404 Not Found"

-- | A 405 "Method Not Allowed" error page.
methodNotAllowed :: Wai.Response
methodNotAllowed = buildError HTTP.methodNotAllowed405 "405 Method Not Allowed"
