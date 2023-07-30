module Quasar.Web (
  DomElement(..),
  DomElementContent(..),

  WebUi(..),
  HtmlElement(..),
) where

import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Quasar
import Quasar.Observable.ObservableList
import Quasar.Observable.ObservableMap
import Quasar.Prelude

data DomElement = DomElement {
  tagName :: Text,
  attributes :: ObservableMap Text (Maybe Text),
  content :: DomElementContent
}

data DomElementContent
--  = Children (ObservableList DomElement)
--  | InnerText (Observable Text)


newtype HtmlElement = HtmlElement TL.Text

data WebUi
--  = WebUiObservable (Observable WebUi) -- "<quasar-splice id="7">...</quasar-splice>
--  | WebUiHtmlElement HtmlElement -- "<p>foobar</p>"
--  | WebUiConcat [WebUi] -- "<a /><b />
--  | WebUiObservableList (ObservableList WebUi)
--  -- | WebUiButton (STMc NoRetry '[] (Future ())) ButtonConfig

data ButtonConfig = ButtonConfig {
  disableOnClick :: Bool
}
