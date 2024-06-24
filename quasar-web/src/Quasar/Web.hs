module Quasar.Web (
  DomNode,
  DomElement(..),
  domElement,
  textNode,
  textElement,

  ComponentCommandSource,
  ComponentEventHandler,
  ComponentInit(..),
  Component(..),

  CreateNodeComponent(..),
  ModifyElementComponent(..),

  ComponentApi(..),

  -- * Internal
  ComponentRef,
  WireNode,
  WireComponent(..),
  Splice(..),
  SpliceCommand(..),
) where

import Control.Monad (mapAndUnzipM)
import Data.Aeson (ToJSON, object, (.=), pairs)
import Data.Aeson qualified as Aeson
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.String (IsString(..))
import Data.Text (Text)
import Quasar.Disposer (TDisposer, isTrivialTDisposer, disposeTDisposer)
import Quasar.Observable.AccumulatingObserver
import Quasar.Observable.Core
import Quasar.Observable.List (ListOperation(..), ObservableList, deltaToOperations)
import Quasar.Observable.List qualified as ObservableList
import Quasar.Observable.Map (ObservableMap)
import Quasar.Observable.Map qualified as ObservableMap
import Quasar.Observable.Traversable
import Quasar.Prelude

type ComponentRef = Word64

type WireNode = WireComponent

data WireComponent
  = WireComponent Text (Maybe ComponentRef) Aeson.Value
  deriving Show

instance ToJSON WireComponent where
  toJSON (WireComponent name ref initData) =
    object ["name" .= name, "ref" .= ref, "data" .= initData]
  toEncoding (WireComponent name ref initData) =
    pairs ("name" .= name <> "ref" .= ref <> "data" .= initData)

data WireElement = WireElement {
  tag :: Text,
  components :: [WireComponent]
}
  deriving Show
instance ToJSON WireElement where
 toJSON (WireElement tag components) =
   object ["tag" .= tag, "components" .= components]
 toEncoding (WireElement tag components) =
   pairs ("tag" .= tag <> "components" .= components)

type DomNode = CreateNodeComponent

instance IsString DomNode where
  fromString x = textNode (fromString x)

data DomElement = DomElement {
  tagName :: Text,
  attributes :: ObservableMap NoLoad '[] Text Text,
  children :: ObservableList NoLoad '[] DomNode,
  components :: [ModifyElementComponent]
}

data ComponentApi = ComponentApi {
  newCreateNodeComponentInstance :: CreateNodeComponent -> STMc NoRetry '[] (WireNode, [Splice]),
  newModifyElementComponentInstance :: ModifyElementComponent -> STMc NoRetry '[] (WireComponent, [Splice])
}

type ComponentCommandSource = (Aeson.Value -> SpliceCommand) -> STMc NoRetry '[] [SpliceCommand]
type ComponentEventHandler =  Aeson.Value -> STMc NoRetry '[] ()
data ComponentInit = ComponentInit {
  free :: STMc NoRetry '[] [SpliceCommand],
  initData :: Aeson.Value,
  commandSource :: ComponentCommandSource,
  eventHandler :: ComponentEventHandler
}
data Component = Component Text (ComponentApi -> STMc NoRetry '[] (Either (Aeson.Value, [Splice]) ComponentInit))

newtype CreateNodeComponent = CreateNodeComponent Component

newtype ModifyElementComponent = ModifyElementComponent Component


data SpliceCommand
  = SpliceFreeRef ComponentRef
  | SpliceComponentCommand ComponentRef Aeson.Value
  deriving Show

data Splice = Splice {
  freeSplice :: STMc NoRetry '[] [SpliceCommand],
  generateSpliceCommands :: STMc NoRetry '[] [SpliceCommand]
}


-- | Create a DOM element.
domElement ::
  Text ->
  ObservableMap NoLoad '[] Text Text ->
  ObservableList NoLoad '[] DomNode ->
  DomNode
domElement tag attributes children = domElement' tag [childrenComponent children]


domElement' ::
  Text ->
  [ModifyElementComponent] ->
  DomNode
domElement' tag components = CreateNodeComponent (Component "element" initializeComponent)
  where
    initializeComponent :: ComponentApi -> STMc NoRetry '[] (Either (Aeson.Value, [Splice]) ComponentInit)
    initializeComponent api = do
      (wireComponents, splices) <- mapAndUnzipM api.newModifyElementComponentInstance components
      pure (Left (Aeson.toJSON (WireElement tag wireComponents), join splices))

-- | Create a text node.
textNode :: Observable NoLoad '[] Text -> DomNode
textNode text = CreateNodeComponent (Component "text" initializeTextComponent)
  where
    initializeTextComponent :: ComponentApi -> STMc NoRetry '[] (Either (Aeson.Value, [Splice]) ComponentInit)
    initializeTextComponent api = do
      updateVar <- newTVar Nothing
      (disposer, initial) <- attachSimpleObserver text (writeTVar updateVar . Just)
      let initData = Aeson.toJSON initial

      if isTrivialTDisposer disposer
        then pure (Left (initData, []))
        else pure (Right ComponentInit {
          free = [] <$ disposeTDisposer disposer,
          initData,
          commandSource = commandSource updateVar,
          eventHandler = const (pure ())
        })

    commandSource :: TVar (Maybe Text) -> ComponentCommandSource
    commandSource var packSpliceCommand = do
      readTVar var >>= \case
        Nothing -> pure []
        Just update -> do
          writeTVar var Nothing
          pure [packSpliceCommand (Aeson.toJSON update)]


childrenComponent :: ObservableList NoLoad '[] DomNode -> ModifyElementComponent
childrenComponent children = ModifyElementComponent (Component "children" initializeComponent)
  where
    initializeComponent :: ComponentApi -> STMc NoRetry '[] (Either (Aeson.Value, [Splice]) ComponentInit)
    initializeComponent api = do
      (maccum, initial) <- attachAccumulatingObserver (toObservableT children)

      let ObservableStateLive (ObservableResultTrivial nodes) = initial
      (initialWireNodes, splices) <- Seq.unzip <$> mapM api.newCreateNodeComponentInstance nodes

      let initData = Aeson.toJSON (toList initialWireNodes)
      case maccum of
        Nothing -> pure (Left (initData, fold splices))
        Just accum -> do
          var <- newTVar (Just (ObserverStateLive (ObservableResultOk splices)))
          let childrenSplice = ChildrenSplice api accum var
          pure (Right ComponentInit {
            free = freeChildrenSplice childrenSplice,
            initData,
            commandSource = generateChildrenSpliceCommands childrenSplice,
            eventHandler = const (pure ())
          })

data ChildrenSplice =
  ChildrenSplice
    ComponentApi
    (AccumulatingObserver NoLoad '[] Seq DomNode)
    (TVar (Maybe (ObserverState NoLoad (ObservableResult '[] Seq) [Splice])))

data ChildrenCommand
  = InsertChild Int WireNode
  | AppendChild WireNode
  | RemoveChild Int
  | ReplaceAllChildren [WireNode]
  deriving Show

instance ToJSON ChildrenCommand where
  toJSON (InsertChild index node) =
    object ["fn" .= ("insert" :: Text), "i" .= index, "node" .= node]
  toJSON (AppendChild element) =
    object ["fn" .= ("append" :: Text), "node" .= element]
  toJSON (RemoveChild index) =
    object ["fn" .= ("remove" :: Text), "i" .= index]
  toJSON (ReplaceAllChildren children) =
    object ["fn" .= ("replace" :: Text), "nodes" .= children]

  toEncoding (InsertChild index element) =
    pairs ("fn" .= ("insert" :: Text) <> "i" .= index <> "node" .= element)
  toEncoding (AppendChild element) =
    pairs ("fn" .= ("append" :: Text) <> "node" .= element)
  toEncoding (RemoveChild index) =
    pairs ("fn" .= ("remove" :: Text) <> "i" .= index)
  toEncoding (ReplaceAllChildren nodes) =
    pairs ("fn" .= ("replace" :: Text) <> "nodes" .= nodes)

freeChildrenSplice :: ChildrenSplice -> STMc NoRetry '[] [SpliceCommand]
freeChildrenSplice (ChildrenSplice _ accum var) = do
  disposeAccumulatingObserver accum
  readTVar var >>= \case
    Nothing -> pure []
    Just state -> do
      writeTVar var Nothing
      fold <$> mapM freeSplice (fold state)

generateChildrenSpliceCommands :: ChildrenSplice -> ComponentCommandSource
generateChildrenSpliceCommands (ChildrenSplice api accum var) packSpliceCommand = do
  containerCommands <- takeAccumulatingObserver accum Live >>= \case
    Nothing -> pure []
    Just change -> do
      readTVar var >>= \case
        Nothing -> pure []
        Just state -> do

          let ctx = state.context
          case validateChange ctx change of
            Nothing -> pure []
            Just validatedChange -> do
              validatedWireAndSpliceChange <- traverse api.newCreateNodeComponentInstance validatedChange
              let wireAndSpliceChange = validatedWireAndSpliceChange.unvalidated
              let wireChange = fst <$> wireAndSpliceChange
              let spliceChange = snd <$> wireAndSpliceChange

              let removedSplices = fold (selectRemovedByChange change state)
              freeCommands <- fold <$> mapM freeSplice removedSplices

              forM_ (applyObservableChange spliceChange state)
                \(_, newState) -> writeTVar var (Just newState)

              pure (freeCommands <> (packSpliceCommand . Aeson.toJSON <$> listChangeCommands ctx wireChange))

  childCommands <- readTVar var >>= \case
    Nothing -> pure []
    Just state -> fold <$> mapM generateSpliceCommands (fold state)

  pure (containerCommands <> childCommands)

listChangeCommands ::
  ObserverContext NoLoad (ObservableResult '[] Seq) ->
  ObservableChange NoLoad (ObservableResult '[] Seq) WireNode ->
  [ChildrenCommand]
listChangeCommands _ctx (ObservableChangeLiveReplace (ObservableResultTrivial xs)) =
  [ReplaceAllChildren (toList xs)]
listChangeCommands ctx (ObservableChangeLiveDelta delta) =
  toCommand <$> deltaToOperations initialListLength delta
  where
    initialListLength = case ctx of
      (ObserverContextLive (Just len)) -> len
      (ObserverContextLive Nothing) -> 0
    toCommand :: ListOperation WireNode -> ChildrenCommand
    toCommand (ListInsert pos value) = InsertChild (fromIntegral pos) value
    toCommand (ListAppend value) = AppendChild value
    toCommand (ListDelete pos) = RemoveChild (fromIntegral pos)


-- | Create a DOM element that contains text.
textElement ::
  Text ->
  ObservableMap NoLoad '[] Text Text ->
  Observable NoLoad '[] Text ->
  DomNode
textElement tag attributes text = domElement tag attributes (ObservableList.singleton (textNode text))



data WebUi
--  = WebUiObservable (Observable WebUi) -- "<quasar-splice id="7">...</quasar-splice>
--  | WebUiHtmlElement HtmlElement -- "<p>foobar</p>"
--  | WebUiConcat [WebUi] -- "<a /><b />
--  | WebUiObservableList (ObservableList WebUi)
--  -- | WebUiButton (STMc NoRetry '[] (Future ())) ButtonConfig

data ButtonConfig = ButtonConfig {
  disableOnClick :: Bool
}
