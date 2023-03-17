module Quasar.Web (
  WebUi(..),
  HtmlElement(..),
) where

import Data.Text.Lazy qualified as TL
import Quasar
import Quasar.Prelude

newtype HtmlElement = HtmlElement TL.Text

data WebUi
  = WebUiObservable (Observable WebUi) -- "<div id="7">...</quasar-splice>
  | WebUiHtmlElement HtmlElement -- "<p>foobar</p>"
  | WebUiConcat [WebUi] -- "<a /><b />
  -- TODO (requires ObservableList)
  -- WebUiObservableList (ObservableList WebUi)
  | WebUiButton (STMc NoRetry '[] (Future ())) DisableOnClick

type DisableOnClick = Bool
