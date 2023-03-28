module Quasar.Web (
  WebUi(..),
  HtmlElement(..),
) where

import Data.Text.Lazy qualified as TL
import Quasar
import Quasar.Observable.ObservableList
import Quasar.Prelude

newtype HtmlElement = HtmlElement TL.Text

data WebUi
  = WebUiObservable (Observable WebUi) -- "<quasar-splice id="7">...</quasar-splice>
  | WebUiHtmlElement HtmlElement -- "<p>foobar</p>"
  | WebUiConcat [WebUi] -- "<a /><b />
  | WebUiObservableList (ObservableList WebUi)
  | WebUiButton (STMc NoRetry '[] (Future ())) ButtonConfig

data ButtonConfig = ButtonConfig {
  disableOnClick :: Bool
}
