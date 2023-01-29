{-# OPTIONS_HADDOCK not-home #-}

module Quasar.Resources.TSimpleDisposer (
  TSimpleDisposerState,
  TSimpleDisposerElement(..),
  TSimpleDisposer(..),
  newUnmanagedTSimpleDisposer,
  disposeTSimpleDisposer,
  disposeTSimpleDisposerElement,
  trivialTSimpleDisposer,
) where

import Quasar.Future
import Quasar.Prelude
import Quasar.Resources.Finalizer
import Quasar.Utils.TOnce

type TSimpleDisposerState = TOnce (STMc NoRetry '[] ()) (Future ())

data TSimpleDisposerElement = TSimpleDisposerElement Unique TSimpleDisposerState Finalizers

newtype TSimpleDisposer = TSimpleDisposer [TSimpleDisposerElement]
  deriving newtype (Semigroup, Monoid)


newUnmanagedTSimpleDisposer :: MonadSTMc NoRetry '[] m => STMc NoRetry '[] () -> m TSimpleDisposer
newUnmanagedTSimpleDisposer fn = do
  key <- newUniqueSTM
  element <-  TSimpleDisposerElement key <$> newTOnce fn <*> newFinalizers
  pure $ TSimpleDisposer [element]

-- | In case of reentry this will return without calling the dispose hander again.
disposeTSimpleDisposer :: MonadSTMc NoRetry '[] m => TSimpleDisposer -> m ()
disposeTSimpleDisposer (TSimpleDisposer elements) = liftSTMc do
  mapM_ disposeTSimpleDisposerElement elements

-- | In case of reentry this will return without calling the dispose hander again.
disposeTSimpleDisposerElement :: TSimpleDisposerElement -> STMc NoRetry '[] ()
disposeTSimpleDisposerElement (TSimpleDisposerElement _ state finalizers) =
  -- Voiding the result fixes the edge case when calling `disposeTSimpleDisposerElement` from the disposer itself
  void $ mapFinalizeTOnce state runDisposeFn
  where
    runDisposeFn :: STMc NoRetry '[] () -> STMc NoRetry '[] (Future ())
    runDisposeFn disposeFn = do
      disposeFn
      runFinalizers finalizers
      pure $ pure ()

-- | A trivial disposer that does not perform any action when disposed.
trivialTSimpleDisposer :: TSimpleDisposer
trivialTSimpleDisposer = mempty
