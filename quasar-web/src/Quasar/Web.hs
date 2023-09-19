module Quasar.Web (
  DomNode(..),
  DomElement(..),
  domElement,
  DomTextNode(..),
  textNode,

  WebUi(..),
  HtmlElement(..),
) where

import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Quasar
import Quasar.Observable.Core
import Quasar.Observable.List
import Quasar.Observable.Map
import Quasar.Prelude
import Data.String (IsString(..))

data DomNode
  = DomNodeElement DomElement
  | DomNodeTextNode DomTextNode

instance IsString DomNode where
  fromString x = DomNodeTextNode (fromString x)

data DomElement = DomElement {
  tagName :: Text,
  attributes :: ObservableMap NoLoad '[] Text (Maybe Text),
  children :: ObservableList NoLoad '[] DomNode
}

newtype DomTextNode
  = DomTextNode (Observable NoLoad '[] Text)

instance IsString DomTextNode where
  fromString x = DomTextNode (fromString x)


domElement ::
  Text ->
  ObservableMap NoLoad '[] Text (Maybe Text) ->
  ObservableList NoLoad '[] DomNode ->
  DomNode
domElement tag attributes children = DomNodeElement (DomElement tag attributes children)

textNode :: Observable NoLoad '[] Text -> DomNode
textNode text = DomNodeTextNode (DomTextNode text)



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
