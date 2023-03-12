module Quasar.Web.Server (
  waiApplication,
) where

import Data.Binary.Builder qualified as Builder
import Data.ByteString qualified as BS
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)
import Quasar.Prelude
import Quasar.Web


waiApplication :: WebUi -> Wai.Application
waiApplication state = Wai.websocketsOr webSocketsOptions (webSocketsApp state) waiApp
  where
    webSocketsOptions = WebSockets.defaultConnectionOptions {WebSockets.connectionStrictUnicode = True}

webSocketsApp :: WebUi -> WebSockets.ServerApp
webSocketsApp = undefined

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
      Builder.fromByteString "<script type=module src=quasar-web-client/index.js></script>",
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
