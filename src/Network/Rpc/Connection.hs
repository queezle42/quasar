module Network.Rpc.Connection where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, link, waitCatch, withAsync)
import Control.Concurrent.MVar
import Control.Exception (Exception(..), SomeException, bracketOnError, finally, throwIO, bracketOnError, onException)
import Control.Monad ((>=>), unless, forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (intercalate)
import GHC.IO (unsafeUnmask)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as Socket
import qualified Network.Socket.ByteString.Lazy as SocketL
import Prelude

-- | Abstraction over a bidirectional stream connection (e.g. a socket), to be able to switch to different communication channels (e.g. stdin/stdout or a dummy implementation for unit tests).
data SocketConnection = SocketConnection {
  send :: BSL.ByteString -> IO (),
  receive :: IO BS.ByteString,
  close :: IO ()
}
class IsSocketConnection a where
  toSocketConnection :: a -> SocketConnection
instance IsSocketConnection SocketConnection where
  toSocketConnection = id
instance IsSocketConnection Socket.Socket where
  toSocketConnection sock = SocketConnection {
    send=SocketL.sendAll sock,
    receive=Socket.recv sock 4096,
    close=Socket.gracefulClose sock 2000
  }


newtype ConnectionFailed = ConnectionFailed [(Socket.AddrInfo, SomeException)]
  deriving (Show)
instance Exception ConnectionFailed where
  displayException (ConnectionFailed attemts) = "Connection attempts failed:\n" <> intercalate "\n" (map (\(addr, err) -> show (Socket.addrAddress addr) <> ": " <> displayException err) attemts)

connectTCP :: Socket.HostName -> Socket.ServiceName -> IO Socket.Socket
connectTCP host port = do
  -- 'getAddrInfo' either pures a non-empty list or throws an exception
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
      forM_ others spawnConnectTask
      -- Wait for all tasks to complete, throw an exception if all connections failed
      connectTasks <- readMVar connectTasksMVar
      results <- mapM (\(addr, task) -> (addr,) <$> waitCatch task) connectTasks
      forM_ (collect results) (throwIO . ConnectionFailed . reverse)
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
    (withAsync (unsafeUnmask raceConnections) (link >=> const (readMVar sockMVar))
      `finally` (mapM_ (cancel . snd) =<< readMVar connectTasksMVar))
        `onException` (mapM_ Socket.close =<< tryTakeMVar sockMVar)
    -- As soon as we have an open connection, stop spawning more connections
  pure sock
  where
    hints :: Socket.AddrInfo
    hints = Socket.defaultHints { Socket.addrFlags = [Socket.AI_ADDRCONFIG], Socket.addrSocketType = Socket.Stream }
    connect :: Socket.AddrInfo -> IO Socket.Socket
    connect addr = bracketOnError (openSocket addr) Socket.close $ \sock -> do
      Socket.withFdSocket sock Socket.setCloseOnExecIfNeeded
      Socket.connect sock $ Socket.addrAddress addr
      pure sock


newDummySocketPair :: IO (SocketConnection, SocketConnection)
newDummySocketPair = do
  upstream <- newEmptyMVar
  downstream <- newEmptyMVar
  let x = SocketConnection {
    send=putMVar upstream . BSL.toStrict,
    receive=takeMVar downstream,
    close=pure ()
  }
  let y = SocketConnection {
    send=putMVar downstream . BSL.toStrict,
    receive=takeMVar upstream,
    close=pure ()
  }
  pure (x, y)



-- | Reimplementation of 'openSocket' from the 'network'-package, which got introduced in version 3.1.2.0. Should be removed later.
openSocket :: Socket.AddrInfo -> IO Socket.Socket
openSocket addr = Socket.socket (Socket.addrFamily addr) (Socket.addrSocketType addr) (Socket.addrProtocol addr)
