{-# OPTIONS_GHC -ddump-splices #-}
{-# OPTIONS_GHC -ddump-to-file #-}

module Quasar.Network.InterfaceSpec (spec) where

import Quasar
import Quasar.Network.TH.Generator
import Quasar.Network.TH.Spec
import Quasar.Prelude
import Test.Hspec.Core.Spec

-- Type is pinned to IO, otherwise hspec spec type cannot be inferred
rm :: QuasarIO a -> IO a
rm = runQuasarCombineExceptions

$(makeInterface $ interface "Foobar" $ do
    addObservable "demoObservable" $ binaryType [t|Bool|]
    --addFunction "demoFunction" do
    --  addArgument "arg0" (binaryType [t|Bool|])
    --  addArgument "arg1" (binaryType [t|Int|])
    --  addResult "result" (binaryType [t|String|])
 )

spec :: Spec
spec = parallel $ describe "generated example interface" do
  it "foobars" $ rm do
    pure ()
