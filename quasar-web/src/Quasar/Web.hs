module Quasar.Web (
  WebUi(..),
  HtmlElement(..),
) where

import Data.ByteString.Lazy qualified as BSL
import Quasar
import Quasar.Prelude

newtype HtmlElement = HtmlElement BSL.ByteString

data WebUi
  = WebUiObservable (Observable WebUi)
  | WebUiHtmlElement HtmlElement
  | WebUiConcat [WebUi]
  -- TODO (requires ObservableCollection)
  -- WebUiObservableCollection (ObservableCollection WebUi)
  | WebUiButton (STMc NoRetry '[] (Future ())) DisableOnClick

type DisableOnClick = Bool
