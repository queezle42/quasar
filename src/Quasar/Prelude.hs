module Quasar.Prelude
  ( module Prelude,
    module Quasar.PreludeExtras,
    (>=>),
    (<=<),
    Control.Applicative.liftA2,
    Data.Foldable.sequenceA_,
    Data.Foldable.traverse_,
    module Control.Concurrent.MVar,
    Control.Exception.Exception,
    Control.Exception.SomeException,
    Control.Exception.throwIO,
    Control.Monad.forever,
    Control.Monad.unless,
    Control.Monad.void,
    Control.Monad.when,
    Control.Monad.forM,
    Control.Monad.forM_,
    Control.Monad.join,
    Data.Unique.Unique,
    Data.Unique.newUnique,
    Data.Void.Void,
    Data.Hashable.Hashable,
    GHC.Generics.Generic,
    MonadIO,
    liftIO,
    Data.Maybe.catMaybes,
    Data.Maybe.fromMaybe,
    Data.Maybe.listToMaybe,
    Data.Maybe.maybeToList,
    Data.Int.Int8,
    Data.Int.Int16,
    Data.Int.Int32,
    Data.Int.Int64,
    Data.Word.Word8,
    Data.Word.Word16,
    Data.Word.Word32,
    Data.Word.Word64,
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

import Prelude hiding
  ( error,
    errorWithoutStackTrace,
    head,
    last,
    read,
    -- Due to the accepted "monad of no return" proposal, return becomes an
    -- alias for pure. Return can be a pitfall for newcomers, so we decided to
    -- use pure instead.
    return,
    undefined,
  )
import Prelude qualified as P

import Control.Applicative qualified
import Control.Concurrent.MVar
import Control.Exception qualified
import Control.Monad ((>=>), (<=<))
import Control.Monad qualified
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable qualified
import Data.Hashable qualified
import Data.Int qualified
import Data.Maybe qualified
import Data.Unique qualified
import Data.Void qualified
import Data.Word qualified
import Debug.Trace qualified as Trace
import GHC.Generics qualified
import GHC.Stack.Types qualified
import GHC.Types qualified
import Quasar.PreludeExtras

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
