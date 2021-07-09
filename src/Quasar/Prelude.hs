{-# LANGUAGE PackageImports #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PolyKinds #-}

module Quasar.Prelude
  ( module BasePrelude,
    module Quasar.PreludeExtras,
    (>=>),
    (<=<),
    Control.Applicative.liftA2,
    Control.Exception.throwIO,
    Control.Monad.forever,
    Control.Monad.unless,
    Control.Monad.void,
    Control.Monad.when,
    Control.Monad.forM,
    Control.Monad.forM_,
    Control.Monad.join,
    Data.Void.Void,
    Hashable.Hashable,
    GHC.Generics.Generic,
    MonadIO,
    liftIO,
    Maybe.catMaybes,
    Maybe.fromMaybe,
    Maybe.listToMaybe,
    Maybe.maybeToList,
    error,
    errorWithoutStackTrace,
    head,
    last,
    read,
    trace,
    traceId,
    traceShow,
    traceShowId,
    traceM,
    traceShowM,
    traceIO,
    traceShowIO,
    traceShowIdIO,
    undefined,
  )
where

import "base" Prelude as BasePrelude hiding
  ( error,
    errorWithoutStackTrace,
    head,
    last,
    read,
    undefined,
  )
import qualified "base" Prelude as P

import Quasar.PreludeExtras

import qualified Control.Applicative
import qualified Control.Exception
import qualified Control.Monad
import qualified Data.Void
import Control.Monad ((>=>), (<=<))
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.Hashable as Hashable
import qualified Data.Maybe as Maybe
import qualified Debug.Trace as Trace
import qualified GHC.Generics
import qualified GHC.Stack.Types
import qualified GHC.Types

{-# DEPRECATED head "Partial Function." #-}
head :: [a] -> a
head = P.head

{-# DEPRECATED last "Partial Function." #-}
last :: [a] -> a
last = P.last

{-# DEPRECATED read "Partial Function." #-}
read :: Read a => String -> a
read = P.read

{-# DEPRECATED error "Undefined." #-}
error :: forall (r :: GHC.Types.RuntimeRep). forall (a :: GHC.Types.TYPE r). GHC.Stack.Types.HasCallStack => String -> a
error = P.error

{-# DEPRECATED errorWithoutStackTrace "Undefined." #-}
errorWithoutStackTrace :: String -> a
errorWithoutStackTrace = P.errorWithoutStackTrace

{-# DEPRECATED undefined "Undefined." #-}
undefined :: forall (r :: GHC.Types.RuntimeRep). forall (a :: GHC.Types.TYPE r). GHC.Stack.Types.HasCallStack  => a
undefined = P.undefined

{-# DEPRECATED trace "Trace." #-}
trace :: String -> a -> a
trace = Trace.trace

{-# DEPRECATED traceId "Trace." #-}
traceId :: String -> String
traceId = Trace.traceId

{-# DEPRECATED traceShow "Trace." #-}
traceShow :: Show a => a -> b -> b
traceShow = Trace.traceShow

{-# DEPRECATED traceShowId "Trace." #-}
traceShowId :: Show a => a -> a
traceShowId = Trace.traceShowId

{-# DEPRECATED traceM "Trace." #-}
traceM :: Applicative m => String -> m ()
traceM = Trace.traceM

{-# DEPRECATED traceShowM "Trace." #-}
traceShowM :: (Show a, Applicative m) => a -> m ()
traceShowM = Trace.traceShowM

{-# DEPRECATED traceIO "Trace." #-}
traceIO :: Control.Monad.IO.Class.MonadIO m => String -> m ()
traceIO = Control.Monad.IO.Class.liftIO . Trace.traceIO

{-# DEPRECATED traceShowIO "Trace." #-}
traceShowIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m ()
traceShowIO = traceIO . show

{-# DEPRECATED traceShowIdIO "Trace." #-}
traceShowIdIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m a
traceShowIdIO a = traceShowIO a >> pure a
