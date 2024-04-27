{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE CPP #-}

module Quasar.Prelude
  ( module Prelude,
    module Quasar.PreludeExtras,
    module Control.Concurrent.STM.Class,
#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
    -- Workaround for https://github.com/haskell/haddock/issues/1601
    Control.Concurrent.STM.Class.RetryKind(..),
#endif
    module Control.Exception.Ex,
    module Control.Monad.CatchC,
    (>=>),
    (<=<),
    (<|>),
    (&),
    (<&>),
#if ! MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
    Control.Applicative.liftA2,
#endif
    Control.Applicative.Alternative,
    Data.Foldable.fold,
    Data.Foldable.sequenceA_,
    Data.Foldable.traverse_,
    Data.Foldable.toList,
    Data.Functor.Identity.Identity(..),
    module Control.Concurrent.MVar,
    Control.Exception.Exception,
    Control.Exception.IOException,
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
    GHC.Stack.HasCallStack,
    Debug.Trace.trace,
    Debug.Trace.traceId,
    Debug.Trace.traceShow,
    Debug.Trace.traceShowId,
    Debug.Trace.traceM,
    Debug.Trace.traceShowM,
    traceIO,
    traceShowIO,
    traceShowIdIO,
  )
where

import Prelude hiding
  ( head,
    last,
    read,
    -- Due to the accepted "monad of no return" proposal, return becomes an
    -- alias for pure. Return can be a pitfall for newcomers, so we decided to
    -- use pure instead.
    return,
  )
import Prelude qualified as P

import Control.Applicative ((<|>))
import Control.Applicative qualified
import Control.Concurrent.MVar
#if MIN_VERSION_GLASGOW_HASKELL(9,6,1,0)
-- Workaround for https://github.com/haskell/haddock/issues/1601
import Control.Concurrent.STM.Class hiding (RetryKind(..), registerDelay)
import Control.Concurrent.STM.Class qualified
#else
import Control.Concurrent.STM.Class hiding (registerDelay)
#endif
import Control.Exception qualified
import Control.Exception.Ex
import Control.Monad ((>=>), (<=<))
import Control.Monad qualified
import Control.Monad.CatchC
import Control.Monad.Fix qualified
import Control.Monad.IO.Class qualified
import Data.Foldable qualified
import Data.Function ((&))
import Data.Functor ((<&>))
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
import GHC.Stack qualified
import GHC.Types qualified
import Quasar.PreludeExtras

traceIO :: Control.Monad.IO.Class.MonadIO m => String -> m ()
traceIO = Control.Monad.IO.Class.liftIO . Debug.Trace.traceIO

traceShowIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m ()
traceShowIO = traceIO . show

traceShowIdIO :: (Control.Monad.IO.Class.MonadIO m, Show a) => a -> m a
traceShowIdIO a = traceShowIO a >> pure a

newUnique :: Control.Monad.IO.Class.MonadIO m => m Data.Unique.Unique
newUnique = Control.Monad.IO.Class.liftIO Data.Unique.newUnique
