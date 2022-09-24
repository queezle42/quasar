{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

module Control.Concurrent.STM.Class.TH (
  mkMonadClassWrapper,
  mkMonadIOWrapper,
  copyDoc,

  -- ** Utils
  tellQs,
) where

import Control.Monad ((<=<))
import Control.Monad.IO.Class
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer
import Language.Haskell.TH
import Prelude

import Debug.Trace (traceShowM)

mkMonadIOWrapper :: Name -> Q [Dec]
mkMonadIOWrapper fqn = mkMonadClassWrapper [t|MonadIO|] [|liftIO|] fqn

mkMonadClassWrapper :: Q Type -> Q Exp -> Name -> Q [Dec]
mkMonadClassWrapper monadClassT liftE fqn = do
  m <- newName "m"
  constraint <- appT monadClassT (varT m)
  monadT <- varT m
  ty <- reifyType fqn
  let name = mkName $ nameBase fqn
  let resultT = replaceMonad monadT (addConstraint constraint ty)
  impl <- mkLiftImpl liftE fqn
  pure $ [SigD name resultT, impl, inlinablePragma name]


addConstraint :: Type -> Type -> Type
-- NOTE Current implementation drops the forall, since that improves
-- documentation readability by a lot. The explicit forall seems to be generated
-- by TH anyway, since it's not part of the original @stm@ signature.
addConstraint constraint (ForallT _ ctx ty) = ForallT [] (constraint : ctx) ty
addConstraint constraint ty = ForallT [] [constraint] ty

replaceMonad :: Type -> Type -> Type
replaceMonad mT = go
  where
    go :: Type -> Type
    go (ForallT tyVars ctx ty) = (ForallT tyVars ctx (go ty))
    go (AppT fx@(AppT ArrowT _) fy) = AppT fx (go fy)
    go (AppT (ConT _prevMonad) ret) = AppT mT ret
    go ty = error $ "Unknown type structure: " <> show (ppr ty)

mkLiftImpl :: Q Exp -> Name -> Q Dec
mkLiftImpl liftE fqn = do
  ty <- reifyType fqn
  let name = mkName $ nameBase fqn
  argNames <- mapM (\_ -> newName "x") [1..(argumentCount ty)]
  let
    argPats = varP <$> argNames
    bodyE = [|$liftE $(foldl appE (varE fqn) (varE <$> argNames))|]
    clauses = [clause argPats (normalB bodyE) []]
#if MIN_VERSION_GLASGOW_HASKELL(9,2,0,0)
  doc <- fmap rewriteDoc <$> getDoc (DeclDoc fqn)
  funD_doc name clauses doc [Nothing]
#else
  funD name clauses
#endif

argumentCount :: Type -> Int
argumentCount (ForallT _ _ ty) = argumentCount ty
argumentCount (AppT (AppT ArrowT _) rhs) = argumentCount rhs + 1
argumentCount _ = 0

inlinablePragma :: Name -> Dec
inlinablePragma name = PragmaD (InlineP name Inlinable FunLike AllPhases)

copyDoc :: Name -> Name -> Q ()
#if MIN_VERSION_GLASGOW_HASKELL(9,2,0,0)
copyDoc target source = do
  doc <- fmap rewriteDoc <$> getDoc (DeclDoc source)
  traceShowM doc
  mapM_ (putDoc (DeclDoc target)) doc
#else
copyDoc _ _ = pure ()
#endif

rewriteDoc :: String -> String
rewriteDoc = unlines . fmap rewriteSince . lines
  where
    rewriteSince ('@':'s':'i':'n':'c':'e':' ':xs) = "/Since: stm-" <> xs <> "/"
    rewriteSince (x:xs) = x : rewriteSince xs
    rewriteSince [] = []

-- * Utils

tellQs :: Monoid a => Q a -> WriterT a Q ()
tellQs = tell <=< lift
