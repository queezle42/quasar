export type Unsubscriber = () => void

export type Extension = {
  components: Component[]
}

export type Ref = number

export type WireNode = WireComponent<null, Node>

//export type WireNode =
//  | { type: "element", ref: Ref | null, tag: string, children: [WireNode], components: [WireComponent<HTMLElement, null>] }
//  | { type: "component" } & WireComponent<null, Node>

export type WireComponent<_i, _o> = { name: string, ref: Ref | null, data: unknown }

export type TypedComponent<t, i, o> = {
  type: t,
  name: string,
  init: ComponentInitFunction<i, o>,
}

export type ComponentInitArguments<i> = { initData: unknown, target: i, componentApi: ComponentApi }

export type ComponentInitFunction<i, o> = (args: ComponentInitArguments<i>) => {
  initConnected: (send: ((data: unknown) => void)) => { output: o, unsubscribe?: Unsubscriber, receive?: (data: unknown) => void },
  initStatic: () => o,
}

export type ComponentApi = {
  readonly createNode: (wireNode: WireNode) => Node,
  readonly attachModifyElementComponent: (wire: WireComponent<HTMLElement, null>, element: HTMLElement) => void,
}

export type Component =
  | TypedComponent<"createNode", null, Node>
  | TypedComponent<"modifyElement", HTMLElement, null>

export function toCreateNodeComponent(component: Component): TypedComponent<"createNode", null, Node> {
  if (component.type != "createNode") {
    throw `[quasar] Component '${component.name}' expected to be of type 'createNode', but is '${component.type}'`;
  }
  return component;
}

export function toModifyElementComponent(component: Component): TypedComponent<"modifyElement", HTMLElement, null> {
  if (component.type != "modifyElement") {
    throw `[quasar] Component '${component.name}' expected to be of type 'modifyElement', but is '${component.type}'`;
  }
  return component;
}
