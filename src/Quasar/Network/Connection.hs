module Quasar.Network.Connection (
  Connection(..),
  IsConnection(..),
  connectTCP,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, link, waitCatch, withAsync)
import Control.Concurrent.MVar
import Control.Exception (Exception(..), bracketOnError, catch, interruptible, finally, bracketOnError, onException)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Socket
import Network.Socket.ByteString.Lazy qualified as SocketL
import Quasar.Prelude

-- | Abstraction over a bidirectional stream connection (e.g. a socket), to be able to switch to different communication channels (e.g. stdin/stdout or a dummy implementation for unit tests).
data Connection = Connection {
  send :: BSL.ByteString -> IO (),
  receive :: IO BS.ByteString,
  -- | Close - expected to be idempotent
  close :: IO ()
}
class IsConnection a where
  toSocketConnection :: a -> Connection
instance IsConnection Connection where
  toSocketConnection = id
instance IsConnection Socket.Socket where
  toSocketConnection sock = Connection {
    send=SocketL.sendAll sock,
    receive=Socket.recv sock 4096,
    -- gracefulClose may fail but guarantees that the socket is deallocated
    close=Socket.gracefulClose sock 2000 `catch` \(_ :: SomeException) -> pure ()
  }


newtype ConnectingFailed = ConnectingFailed [(Socket.AddrInfo, SomeException)]
  deriving stock (Show)
instance Exception ConnectingFailed where
  displayException (ConnectingFailed attemts) = "Connection attempts failed:\n" <> intercalate "\n" (map (\(addr, err) -> show (Socket.addrAddress addr) <> ": " <> displayException err) attemts)

-- | Open a TCP connection to target host and port. Will start multiple connection attempts (i.e. retry quickly and then try other addresses) but only return the first successful connection.
-- Throws a 'ConnectionFailed' on failure, which contains the exceptions from all failed connection attempts.
connectTCP :: MonadIO m => Socket.HostName -> Socket.ServiceName -> m Socket.Socket
connectTCP host port = liftIO do
  -- 'getAddrInfo' either pures a non-empty list or throws an exception
  -- TODO simultaneous v4 and v6 resolution (see RFC 8305)
  -- TODO sort responses (e.g. give private range IPs priority)
  (best:others) <- Socket.getAddrInfo (Just hints) (Just host) (Just port)

  connectTasksMVar <- newMVar []
  sockMVar <- newEmptyMVar
  let
    spawnConnectTask :: Socket.AddrInfo -> IO ()
    spawnConnectTask = \addr -> modifyMVar_ connectTasksMVar $ \old -> (:old) . (addr,) <$> connectTask addr
    -- Race more connections (a missed TCP SYN will result in 3s wait before a retransmission; IPv6 might be broken)
    -- Inspired by a similar implementation in browsers
    raceConnections :: IO ()
    raceConnections = do
      spawnConnectTask best
      threadDelay 200000
      -- Give the "best" address another try, in case the TCP SYN gets dropped (kernel retry interval can be multiple seconds long)
      spawnConnectTask best
      threadDelay 100000
      -- Try to connect to all other resolved addresses to prevent waiting for e.g. a long IPv6 connection timeout
      -- TODO space out further connections (see RFC 8305)
      forM_ others spawnConnectTask
      -- Wait for all tasks to complete, throw an exception if all connections failed
      connectTasks <- readMVar connectTasksMVar
      results <- mapM (\(addr, task) -> (addr,) <$> waitCatch task) connectTasks
      forM_ (collect results) (throwIO . ConnectingFailed . reverse)
    collect :: [(Socket.AddrInfo, Either SomeException ())] -> Maybe [(Socket.AddrInfo, SomeException)]
    collect ((_, Right ()):_) = Nothing
    collect ((addr, Left ex):xs) = ((addr, ex):) <$> collect xs
    collect [] = Just []
    connectTask :: Socket.AddrInfo -> IO (Async ())
    connectTask addr = async $ do
      sock <- connect addr
      isFirst <- tryPutMVar sockMVar sock
      unless isFirst $ Socket.close sock

  -- The 'raceConnections'-async is 'link'ed to this thread, so 'readMVar' is interrupted when all connection attempts fail
  sock <-
    (withAsync (interruptible raceConnections) (link >=> const (readMVar sockMVar))
      -- As soon as we have an open connection, stop spawning more connections
      `finally` (mapM_ (cancel . snd) =<< readMVar connectTasksMVar))
        `onException` (mapM_ Socket.close =<< tryTakeMVar sockMVar)
  pure sock
  where
    hints :: Socket.AddrInfo
    hints = Socket.defaultHints { Socket.addrFlags = [Socket.AI_ADDRCONFIG], Socket.addrSocketType = Socket.Stream }
    connect :: Socket.AddrInfo -> IO Socket.Socket
    connect addr = bracketOnError (openSocket addr) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.connect sock $ Socket.addrAddress addr
      pure sock


-- | Reimplementation of 'openSocket' from the 'network'-package, which got introduced in version 3.1.2.0. Should be removed later.
openSocket :: Socket.AddrInfo -> IO Socket.Socket
openSocket addr = Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)
