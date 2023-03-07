module Quasar.Web.Server (
  waiApplication,
) where

import Quasar.Prelude
import Quasar.Web
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as Wai
import Network.WebSockets qualified as WebSockets
import Paths_quasar_web (getDataFileName)


waiApplication :: WebUi -> Wai.Application
waiApplication state = Wai.websocketsOr webSocketsOptions (webSocketsApp state) waiApp
  where
    webSocketsOptions = WebSockets.defaultConnectionOptions {WebSockets.connectionStrictUnicode = True}

webSocketsApp :: WebUi -> WebSockets.ServerApp
webSocketsApp = undefined

waiApp :: Wai.Application
waiApp req respond = undefined
