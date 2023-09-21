module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Network.Wai.Handler.Warp
import Quasar
import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Observable.List as ObservableList
import Quasar.Observable.Map as ObservableMap
import Quasar.Observable.ObservableVar
import Quasar.Prelude
import Quasar.Web
import Quasar.Web.Server (toWaiApplication)
import System.IO (hPutStrLn, stderr)
import System.Random

main :: IO ()
main = runQuasarAndExit do
  var <- newObservableVarIO (0 :: Int)
  async_ $ forever do
    atomically $ modifyObservableVar var (+ 1)
    liftIO $ threadDelay 1_000_000

  let rootDiv = domElement "div" mempty (ObservableList.fromList [
          "hello world!",
          domElement "br" mempty mempty,
          textNode (liftObservable (T.pack . show <$> toObservable var))
        ])

  liftIO $ runSettings settings $ toWaiApplication rootDiv
  where
    port :: Port
    port = 9013
    settings =
      setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port)) $
      setPort port
      defaultSettings

