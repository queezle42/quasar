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
  a <- newObservableVarIO (0 :: Int)
  b <- newObservableVarIO (0 :: Int)
  c <- newObservableVarIO undefined

  void $ forkIO $ forever do
    atomically do
      v <- stateObservableVar a (\x -> (x + 1, x + 1))
      when (v `mod` 10 == 0) do
        modifyObservableVar b (+ 10)
      when (v `mod` 7 == 0) do
        writeObservableVar c (WebUiHtmlElement (HtmlElement "🐿"))
      when (v `mod` 7 == 1) do
        writeObservableVar c do
          WebUiConcat [
            WebUiObservable (toSpan <$> toObservable a),
            WebUiHtmlElement (HtmlElement "/"),
            WebUiObservable (toSpan <$> toObservable b)
            ]
    threadDelay 1_000_000

  runSettings settings $ waiApplication do
    WebUiObservable (toObservable c)
  where
    port :: Port
    port = 9013
    settings =
      (setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port))) $
      (setPort port)
      defaultSettings

toSpan :: Show a => a -> WebUi
toSpan x = WebUiHtmlElement (HtmlElement (mconcat ["<span>", TL.pack (show x), "</span>"]))
