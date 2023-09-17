module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Options.Applicative
import Quasar
import Quasar.Network
import Quasar.Network.Client
import Quasar.Network.Connection (connectUnix)
import Quasar.Observable.Core
import Quasar.Observable.Lift
import Quasar.Observable.ObservableVar
import Quasar.Observable.Loading
import Quasar.Prelude
import System.IO (putStrLn, hPutStrLn, stderr)

-- | Main entry point and argument parser.
main :: IO ()
main = join (customExecParser (prefs showHelpOnEmpty) parser)
  where
    parser :: ParserInfo (IO ())
    parser = info (mainParser <**> helper)
      (fullDesc <> header "network-counting - quasar example that counts connected clients")

    mainParser :: Parser (IO ())
    mainParser = hsubparser (
        command "server" (info (pure serverMain) (progDesc "Run the server.")) <>
        command "client" (info (pure clientMain) (progDesc "Run the client."))
      )

-- | Protocol definition, shared between client and server.
type Protocol = Observable Load '[SomeException] Int

-- | Unix socket location.
socketPath :: FilePath
socketPath = "/tmp/quasar-network-counting.sock"

-- | Server entry point
serverMain :: IO ()
serverMain = runQuasarAndExit do
  var <- newObservableVarIO 1

  async_ $ forever do
    atomically $ modifyObservableVar var (+ 1)
    liftIO $ threadDelay 1_000_000

  listenUnix (simpleServerConfig @Protocol (liftObservable (toObservable var))) socketPath

-- | Client entry point
clientMain :: IO ()
clientMain = runQuasarAndExit do
  withReconnectingClient @() @Protocol (connectUnix socketPath) () \client -> do
    let
      observable :: Observable NoLoad '[SomeException] String
      observable = stripLoading "loading" (show <$> join (toObservable client))

    atomicallyC do
      (_disposer, initial) <- attachSimpleObserver (observable `catchAllObservable` (pure . show)) queueLogInfo
      queueLogInfo initial

    sleepForever
