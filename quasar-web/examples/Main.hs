module Main (main) where

import Network.Wai.Handler.Warp
import Quasar.Prelude
import Quasar.Web.Server (waiApplication)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = runSettings settings (waiApplication undefined)
  where
    port :: Port
    port = 9013
    settings =
      (setBeforeMainLoop (hPutStrLn stderr ("Listening on " <> show port))) $
      (setPort port)
      defaultSettings
