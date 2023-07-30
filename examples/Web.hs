module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Network.Wai.Handler.Warp
import Quasar
import Quasar.Observable.ObservableMap as ObservableMap
import Quasar.Observable.ObservableList as ObservableList
import Quasar.Prelude
import Quasar.Web
import Quasar.Web.Server (toWaiApplication)
import System.IO (hPutStrLn, stderr)
import System.Random

main :: IO ()
main = undefined
--main = do
--  a <- newObservableVarIO (0 :: Int)
--  b <- newObservableVarIO (0 :: Int)
--  elements <- ObservableList.newObservableListVarIO [
--    DomElement "span" mempty (InnerText (T.pack . show <$> toObservable a)),
--    undefined]
--  let rootDiv = DomElement "div" mempty (Children (toObservableList elements))
--
--  void $ forkIO $ forever do
--    atomically do
--      v <- stateObservableVar a (\x -> (x + 1, x + 1))
--      when (v `mod` 10 == 0) do
--        modifyObservableVar b (+ 10)
--      when (v `mod` 23 == 0) do
--        ObservableList.insert 1 (DomElement "span" mempty (InnerText "🐿")) elements
--      when (v `mod` 23 == 1) do
--        ObservableList.delete 1 elements
--    threadDelay 1_000_000
--
--  runSettings settings $ toWaiApplication rootDiv
--  where
--    port :: Port
--    port = 9013
--    settings =
--      setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port)) $
--      setPort port
--      defaultSettings
--
--toSpan :: Show a => a -> WebUi
--toSpan x = WebUiHtmlElement (HtmlElement (mconcat ["<span>", TL.pack (show x), "</span>"]))

-- main :: IO ()
-- main = do
--   a <- newObservableVarIO (0 :: Int)
--   b <- newObservableVarIO (0 :: Int)
--   c <- newObservableVarIO (WebUiConcat [])
--   d <- newObservableMapVarIO
--
--   void $ forkIO $ forever do
--     atomically do
--       v <- stateObservableVar a (\x -> (x + 1, x + 1))
--       when (v `mod` 10 == 0) do
--         modifyObservableVar b (+ 10)
--       when (v `mod` 23 == 0) do
--         writeObservableVar c (WebUiHtmlElement (HtmlElement "🐿"))
--       when (v `mod` 23 == 1) do
--         writeObservableVar c do
--           WebUiConcat [
--             WebUiObservable (toSpan <$> toObservable a),
--             WebUiHtmlElement (HtmlElement "/"),
--             WebUiObservable (toSpan <$> toObservable b),
--             WebUiObservableList (ObservableMap.values (ObservableMap.filterWithKey (\k _ -> k < 50) d))
--             ]
--     threadDelay 1_000_000
--
--   void $ forkIO $ forever do
--     x <- randomRIO @Int (0, 100)
--     atomically do
--       ObservableMap.insert x (WebUiHtmlElement (HtmlElement ("<div>" <> TL.pack (show x) <> "</div>"))) d
--     threadDelay 1_000_000
--     y <- randomRIO @Int (0, 100)
--     atomically do
--       ObservableMap.delete y d
--     threadDelay 700_000
--
--   runSettings settings $ waiApplication do
--     WebUiObservable (toObservable c)
--   where
--     port :: Port
--     port = 9013
--     settings =
--       setBeforeMainLoop (hPutStrLn stderr ("Listening on port " <> show port)) $
--       setPort port
--       defaultSettings
--
-- toSpan :: Show a => a -> WebUi
-- toSpan x = WebUiHtmlElement (HtmlElement (mconcat ["<span>", TL.pack (show x), "</span>"]))
