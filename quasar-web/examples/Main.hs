module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Data.Text.Lazy qualified as TL
import Network.Wai.Handler.Warp
import Quasar
import Quasar.Prelude
import Quasar.Web
import Quasar.Web.Server (waiApplication)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  a <- newObservableVarIO (1 :: Int)
  b <- newObservableVarIO (0 :: Int)

  void $ forkIO $ forever do
    v <- atomically $ stateObservableVar a (\x -> (x, x + 1))
    when (v `mod` 10 == 0) do
      atomically $ modifyObservableVar b (+ 10)
    threadDelay 1_000_000

  runSettings settings $ waiApplication do
    WebUiConcat [
      WebUiObservable (toSpan <$> toObservable a),
      WebUiHtmlElement (HtmlElement "/"),
      WebUiObservable (toSpan <$> toObservable b)
      ]
  where
    port :: Port
    port = 9013
    settings =
      (setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port))) $
      (setPort port)
      defaultSettings

toSpan :: Show a => a -> WebUi
toSpan x = WebUiHtmlElement (HtmlElement (mconcat ["<span>", TL.pack (show x), "</span>"]))
