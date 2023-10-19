module Quasar.Web.Server (
  toWaiApplication,
) where

import Control.Monad.Catch
import Data.Aeson (Value, ToJSON, FromJSON, object, (.=), pairs, (.:))
import Data.Aeson qualified as Aeson
import Data.Binary.Builder qualified as Binary
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List qualified as List
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)
import Quasar
import Quasar.Prelude
import Quasar.Web


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
  nextComponentRef <- newTVarIO 0
  componentEventHandlers <- newTVarIO mempty
  let client = Client { nextComponentRef, componentEventHandlers }
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

data Client = Client {
  nextComponentRef :: TVar ComponentRef,
  componentEventHandlers :: TVar (HashMap ComponentRef ComponentEventHandler)
}

newComponentRef :: Client -> STMc NoRetry '[] ComponentRef
newComponentRef client = do
  stateTVar client.nextComponentRef \i -> (i, i + 1)

receiveThread :: Client -> WebSockets.Connection -> QuasarIO ()
receiveThread client connection = liftIO do
  handleWebsocketException connection $ forever do
      WebSockets.receiveDataMessage connection >>= \case
        WebSockets.Binary _ -> WebSockets.sendCloseCode connection 1002 ("Client must not send binary data." :: BS.ByteString)
        WebSockets.Text msg _ -> messageHandler client connection msg

sendThread :: Client -> DomNode -> WebSockets.Connection -> QuasarIO ()
sendThread client rootNode connection = do
  traceIO "[quasar-web] new client"
  (wireNode, splice) <- atomically $ liftSTMc $ newDomNodeSplice client rootNode
  let initialMessage = [SetRoot wireNode]
  liftIO $ WebSockets.sendTextData connection (Aeson.encode initialMessage)
  handleAll (\ex -> atomicallyC (fold <$> mapM freeSplice splice) >> throwM ex) do
    forever do
      updates <- atomically $ do
        updates <- liftSTMc $ fold <$> mapM generateSpliceCommands splice
        check (not (null updates))
        pure updates
      liftIO $ WebSockets.sendTextData connection (Aeson.encode (SpliceCommand <$> updates))


handleWebsocketException :: WebSockets.Connection -> IO () -> IO ()
handleWebsocketException connection =
  handle \case
    WebSockets.CloseRequest _ _ -> pure ()
    WebSockets.ConnectionClosed -> pure ()
    WebSockets.ParseException _ -> WebSockets.sendCloseCode connection 1001 ("WebSocket communication error." :: BS.ByteString)
    WebSockets.UnicodeException _ -> WebSockets.sendCloseCode connection 1001 ("Client sent invalid UTF-8." :: BS.ByteString)

messageHandler :: Client -> WebSockets.Connection -> BSL.ByteString -> IO ()
messageHandler client connection msg = do
  events :: [Event] <- Aeson.throwDecode msg
  mapM_ eventHandler events
  where
    eventHandler :: Event -> IO ()
    eventHandler Ping = WebSockets.sendTextData connection (Aeson.encode [Pong])
    eventHandler (ComponentEvent ref cmd) = do
      componentEventHandlers <- readTVarIO client.componentEventHandlers
      -- Ignores invalid refs, which is required because messages might still be in
      -- flight while a ref is freed.
      forM_ (HM.lookup ref componentEventHandlers) \componentHandler ->
        atomicallyC $ componentHandler cmd
    eventHandler (AckFree ref) = pure ()



data Command
  = SetRoot WireNode
  | SpliceCommand SpliceCommand
  | Pong
  deriving Show

data Event
  = Ping
  | ComponentEvent ComponentRef Value
  | AckFree ComponentRef
  deriving Show

--data WireNode
--  = WireNodeElement WireElement
--  | WireNodeComponent WireComponent
--  deriving Show

data WireElement = WireElement {
  ref :: Maybe ComponentRef,
  tag :: Text,
  children :: [WireNode],
  components :: [WireComponent]
}
  deriving Show

data WireText = WireText (Maybe ComponentRef) Text
  deriving Show

instance ToJSON Command where
  toJSON (SetRoot wire) =
    object ["fn" .= ("root" :: Text), "node" .= wire]
  toJSON (SpliceCommand (SpliceFreeRef ref)) =
    object ["fn" .= ("free" :: Text), "ref" .= ref]
  toJSON (SpliceCommand (SpliceComponentCommand ref cmdData)) =
    object ["fn" .= ("component" :: Text), "ref" .= ref, "data" .= cmdData]
  toJSON Pong =
    object ["fn" .= ("pong" :: Text)]

  toEncoding (SetRoot wire) =
    pairs ("fn" .= ("root" :: Text) <> "node" .= wire)
  toEncoding (SpliceCommand (SpliceFreeRef ref)) =
    pairs ("fn" .= ("free" :: Text) <> "ref" .= ref)
  toEncoding (SpliceCommand (SpliceComponentCommand ref cmdData)) =
    pairs ("fn" .= ("component" :: Text) <> "ref" .= ref <> "data" .= cmdData)
  toEncoding Pong =
    pairs ("fn" .= ("pong" :: Text))

instance FromJSON Event where
  parseJSON = Aeson.withObject "Event" \obj ->
    obj .: "fn" >>= \case
      "ping" -> pure Ping
      "component" -> ComponentEvent <$> obj .: "ref" <*> obj .: "data"
      "ackFree" -> AckFree <$> obj .: "ref"
      (fn :: Text) -> fail $ "Invalid event name: " <> show fn


newDomNodeSplice :: Client -> DomNode -> STMc NoRetry '[] (WireNode, [Splice])
newDomNodeSplice client (CreateNodeComponent component) = do
  (wireComponent, splices) <- newComponentInstance client component
  pure (wireComponent, splices)


newtype ComponentInstance = ComponentInstance (TVar (Maybe ComponentInstanceContent))

data ComponentInstanceContent = ComponentInstanceContent {
  freeInstanceRefs :: STMc NoRetry '[] [SpliceCommand],
  generateComponentSpliceCommands :: STMc NoRetry '[] [SpliceCommand]
}

freeComponentInstance :: ComponentInstance -> STMc NoRetry '[] [SpliceCommand]
freeComponentInstance (ComponentInstance var) = do
  readTVar var >>= \case
    Nothing -> pure []
    Just content -> do
      writeTVar var Nothing
      content.freeInstanceRefs

generateComponentInstanceCommands :: ComponentInstance -> STMc NoRetry '[] [SpliceCommand]
generateComponentInstanceCommands (ComponentInstance var) = do
  readTVar var >>= \case
    Nothing -> pure []
    Just content -> content.generateComponentSpliceCommands

newComponentInstance :: Client -> Component -> STMc NoRetry '[] (WireComponent, [Splice])
newComponentInstance client (Component name componentInitFn) = do
  let componentApi = ComponentApi {
        newCreateNodeComponentInstance = \(CreateNodeComponent component) -> newComponentInstance client component,
        newModifyElementComponentInstance = \(ModifyElementComponent component) -> newComponentInstance client component
      }
  componentInitFn componentApi >>= \case
    Left (initData, splices) -> do
      pure (WireComponent name Nothing initData, splices)
    Right (ComponentInit{free, initData, commandSource, eventHandler}) -> do
      ref <- newComponentRef client
      let content = ComponentInstanceContent {
        freeInstanceRefs = freeHandler free ref,
        generateComponentSpliceCommands = commandSource (SpliceComponentCommand ref)
      }
      componentInstance <- ComponentInstance <$> newTVar (Just content)
      modifyTVar client.componentEventHandlers (HM.insert ref eventHandler)
      let splice = Splice {
        freeSplice = freeComponentInstance componentInstance,
        generateSpliceCommands = generateComponentInstanceCommands componentInstance
      }
      pure (WireComponent name (Just ref) initData, [splice])
  where
    freeHandler :: STMc NoRetry '[] [SpliceCommand] -> ComponentRef -> STMc NoRetry '[] [SpliceCommand]
    freeHandler freeFn ref = do
        refs <- freeFn
        modifyTVar client.componentEventHandlers (HM.delete ref)
        pure (SpliceFreeRef ref:refs)


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
