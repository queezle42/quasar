module Quasar.Prelude
  ( module Prelude,
    module Quasar.PreludeExtras,
    module Quasar.PreludeSTM,
    (>=>),
    (<=<),
    (<|>),
    Control.Applicative.liftA2,
    Control.Applicative.Alternative,
    Data.Foldable.sequenceA_,
    Data.Foldable.traverse_,
    Data.Functor.Identity.Identity,
    module Control.Concurrent.MVar,
    Control.Exception.Exception,
    Control.Exception.SomeException,
    Control.Exception.throwIO,
    Control.Monad.forM,
    Control.Monad.forM_,
    Control.Monad.forever,
    Control.Monad.join,
    Control.Monad.replicateM,
    Control.Monad.replicateM_,
    Control.Monad.unless,
    Control.Monad.void,
    Control.Monad.when,
    Control.Monad.Fix.MonadFix(..),
    Data.Kind.Type,
    Data.Kind.Constraint,
    Data.Unique.Unique,
    newUnique,
    Data.Void.Void,
    Data.Hashable.Hashable,
    GHC.Generics.Generic,
    Control.Monad.IO.Class.MonadIO,
    Control.Monad.IO.Class.liftIO,
    Data.Maybe.catMaybes,
    Data.Maybe.fromMaybe,
    Data.Maybe.isJust,
    Data.Maybe.isNothing,
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
    Debug.Trace.trace,
    Debug.Trace.traceId,
    Debug.Trace.traceShow,
    Debug.Trace.traceShowId,
    Debug.Trace.traceM,
    Debug.Trace.traceShowM,
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

import Control.Applicative ((<|>))
import Control.Applicative qualified
import Control.Concurrent.MVar
import Control.Exception qualified
import Control.Monad ((>=>), (<=<))
import Control.Monad qualified
import Control.Monad.Fix qualified
import Control.Monad.IO.Class qualified
import Data.Foldable qualified
import Data.Functor.Identity qualified
import Data.Hashable qualified
import Data.Int qualified
import Data.Kind qualified
import Data.Maybe qualified
import Data.Unique qualified
import Data.Void qualified
import Data.Word qualified
import Debug.Trace qualified
import GHC.Generics qualified
import GHC.Stack.Types qualified
import GHC.Types qualified
import Quasar.PreludeExtras
import Quasar.PreludeSTM

{-# WARNING error "Undefined." #-}
error :: forall (r :: GHC.Types.RuntimeRep). forall (a :: GHC.Types.TYPE r). GHC.Stack.Types.HasCallStack => String -> a
error = P.error

{-# WARNING errorWithoutStackTrace "Undefined." #-}
errorWithoutStackTrace :: String -> a
errorWithoutStackTrace = P.errorWithoutStackTrace

{-# WARNING undefined "Undefined." #-}
undefined :: forall (r :: GHC.Types.RuntimeRep). forall (a :: GHC.Types.TYPE r). GHC.Stack.Types.HasCallStack => a
undefined = P.undefined

traceIO :: Control.Monad.IO.Class.MonadIO m => String -> m ()
traceIO = Control.Monad.IO.Class.liftIO . Debug.Trace.traceIO

traceShowIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m ()
traceShowIO = traceIO . show

traceShowIdIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m a
traceShowIdIO a = traceShowIO a >> pure a

newUnique :: Control.Monad.IO.Class.MonadIO m => m Data.Unique.Unique
newUnique = Control.Monad.IO.Class.liftIO Data.Unique.newUnique
