{-# LANGUAGE OverloadedLists #-}

module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Data.String (fromString)
import Data.Text (Text)
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
    atomically $ modifyObservableVar var (\x -> x `mod` 100 + 1)
    liftIO $ threadDelay 1_000_000

  let
    squirrelFn :: Int -> Observable NoLoad '[] Text
    squirrelFn x = do
        isSquirrel <- skipRedundantUpdates ((== x) <$> toObservable var)
        if isSquirrel
          then "🐿"
          else fromString (show x)

  mapVar <- ObservableMap.newVarIO mempty
  async_ $ forever do
    x <- randomRIO @Int (1, 100)
    atomically do
      ObservableMap.insertVar mapVar x (squirrelFn x)
    liftIO $ threadDelay 1_000_000
    y <- randomRIO @Int (1, 100)
    atomically do
      ObservableMap.deleteVar mapVar y
    liftIO $ threadDelay 700_000

  let rootDiv = domElement "div" mempty (ObservableList.fromList [
          "hello world!",
          domElement "br" mempty mempty,
          textNode (liftObservable (T.pack . show <$> toObservable var)),
          domElement "ul" mempty (textElement "li" mempty <$> ObservableMap.values (toObservableMap mapVar))
        ])

  liftIO $ runSettings settings $ toWaiApplication rootDiv
  where
    port :: Port
    port = 9013
    settings =
      setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port)) $
      setPort port
      defaultSettings
