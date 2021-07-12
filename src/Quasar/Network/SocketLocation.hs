module Quasar.Network.SocketLocation where

import Control.Exception (handle)
import Quasar.Prelude
import System.Environment (getEnv)

systemSocketPath :: String -> IO FilePath
systemSocketPath appId = pure $ "/run/" <> appId

userSocketPath :: String -> IO FilePath
userSocketPath appId = do
  xdgRuntimeDir <- getEnv "XDG_RUNTIME_DIR"
  pure $ xdgRuntimeDir <> "/" <> appId

sessionSocketPath :: String -> IO FilePath
sessionSocketPath appId = do
  waylandSocketPath' <- waylandSocketPath
  maybe fallbackSocketPath pure waylandSocketPath'
  where
    waylandSocketPath :: IO (Maybe FilePath)
    waylandSocketPath = handleEnvError $ do
      xdgRuntimeDir <- getEnv "XDG_RUNTIME_DIR"
      waylandDisplay <- getEnv "WAYLAND_DISPLAY"
      pure $ xdgRuntimeDir <> "/" <> waylandDisplay <> "-" <> appId
    fallbackSocketPath :: IO FilePath
    fallbackSocketPath = do
      xdgRuntimeDir <- getEnv "XDG_RUNTIME_DIR"
      pure $ xdgRuntimeDir <> "/" <> appId
    handleEnvError :: IO FilePath -> IO (Maybe FilePath)
    handleEnvError = handle (const $ pure Nothing :: IOError -> IO (Maybe FilePath)) . fmap Just
