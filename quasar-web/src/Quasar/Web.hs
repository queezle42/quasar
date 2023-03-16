module Quasar.Web (
  WebUi(..),
  HtmlElement(..),
) where

import Data.ByteString.Lazy qualified as BSL
import Quasar
import Quasar.Prelude

newtype HtmlElement = HtmlElement BSL.ByteString

data WebUi
  = WebUiObservable (Observable WebUi) -- "<div id="7">...</quasar-splice>
  | WebUiHtmlElement HtmlElement -- "<p>foobar</p>"
  | WebUiConcat [WebUi] -- "<a /><b />
  -- TODO (requires ObservableList)
  -- WebUiObservableList (ObservableList WebUi)
  | WebUiButton (STMc NoRetry '[] (Future ())) DisableOnClick

type DisableOnClick = Bool
