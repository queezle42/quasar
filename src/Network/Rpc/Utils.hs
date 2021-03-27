module Network.Rpc.Utils where

import Control.Monad.State as State
import Lens.Micro
import Prelude

-- | Modify the target(s) of a 'Lens'', 'Iso', 'Setter' or 'Traversal' by 'mappend'ing a value.
--
-- >>> execState (do _1 <>= Sum c; _2 <>= Product d) (Sum a,Product b)
-- (Sum {getSum = a + c},Product {getProduct = b * d})
--
-- >>> execState (both <>= "!!!") ("hello","world")
-- ("hello!!!","world!!!")
--
-- @
-- ('<>=') :: ('MonadState' s m, 'Monoid' a) => 'Setter'' s a -> a -> m ()
-- ('<>=') :: ('MonadState' s m, 'Monoid' a) => 'Iso'' s a -> a -> m ()
-- ('<>=') :: ('MonadState' s m, 'Monoid' a) => 'Lens'' s a -> a -> m ()
-- ('<>=') :: ('MonadState' s m, 'Monoid' a) => 'Traversal'' s a -> a -> m ()
-- @
--
-- Copied from the @lens@-library because it is missing in @microlens@.
(<>=) :: (MonadState s m, Monoid a) => ASetter' s a -> a -> m ()
l <>= a = State.modify (l <>~ a)
{-# INLINE (<>=) #-}
