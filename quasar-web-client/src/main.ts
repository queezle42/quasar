// Package entry point
// Reexport public api here

import {
  Component,
  ComponentApi,
  Extension,
  Ref,
  TypedComponent,
  Unsubscriber,
  WireComponent,
  WireNode,
  toCreateNodeComponent,
  toModifyElementComponent,
} from "./components/api"
import { coreComponents } from "./components/core"

const maxReconnectDelayMs = 10_000;
const pingIntervalMs = 2_000;
const pingTimeoutMs = 1_000;

enum State {
  Initial,
  Connecting,
  Connected,
  WaitingForReconnect,
  Reconnecting,
  Closed
}

type Command =
  | { fn: "pong" }
  | { fn: "root", node: WireNode }
  | { fn: "insert", ref: Ref, i: number, node: WireNode }
  | { fn: "append", ref: Ref, node: WireNode }
  | { fn: "remove", ref: Ref, i: number }
  | { fn: "replace", ref: Ref, nodes: [WireNode] }
  | { fn: "free", ref: Ref }
  | { fn: "component", ref: Ref, data: unknown }

type Event =
  | { fn: "ping" }
  | { fn: "component", ref: Ref, data: unknown }
  | { fn: "ackFree", ref: Ref }

class ComponentInstance {
  private alive: boolean = true;
  private unsubscribers: Unsubscriber[] = [];
  private _commandHandler: ((data: unknown) => void) | null = null;
  public get commandHandler(): ((data: unknown) => void) | null {
    return this._commandHandler;
  }
  public set commandHandler(receive: ((data: unknown) => void) | null) {
    if (this.alive) {
      this._commandHandler = receive;
    }
  }

  constructor(private client: QuasarWebClient, private ref: Ref, readonly component: Component) {
  }

  addUnsubscriber(unsubscribe: Unsubscriber) {
    if (this.alive) {
      this.unsubscribers.push(unsubscribe);
    }
    else {
      unsubscribe();
    }
  }

  sendComponentEvent(data: unknown) {
    if (!this.alive) {
      throw `[quasar] Cannot send event for component ${this.ref} because its ref has been freed.`;
    }
    this.client.sendComponentEvent(this.ref, data);
  }

  /**
  * Only to be called by ComponentInstanceRegistry (the instance has to be removed
  * from the registry on free)
  */
  freeRef() {
    if (this.alive) {
      this.alive = false;
      this._commandHandler = null;
      for (let unsubscriber of this.unsubscribers) {
        unsubscriber();
      }
      this.unsubscribers = [];
    }
  }
}

class ComponentRegistry {
  private components: Map<string, Component> = new Map();
  private instances: Map<Ref, ComponentInstance> = new Map();
  private componentApi: ComponentApi;

  constructor(private client: QuasarWebClient) {
    this.componentApi = {
      createNode: wireNode => client.createNode(wireNode),
      attachModifyElementComponent: (wireComponent, element) => this.initializeModifyElementComponent(wireComponent, element),
    };
  }

  registerComponent(component: Component, force: boolean = false) {
    if (!force && this.components.get(component.name)) {
      throw `[quasar] Cannot register a component with name '${component.name}' because another component with that name was already registered`;
    }
    this.components.set(component.name, component);
  }

  registerComponents(components: readonly Component[], force: boolean = false) {
    for (const component of components) {
      this.registerComponent(component, force);
    }
  }

  initializeCreateNodeComponent(wire: WireComponent<null, Node>): Node {
    return this.initializeComponent(wire, null, toCreateNodeComponent);
  }

  initializeModifyElementComponent(wire: WireComponent<HTMLElement, null>, element: HTMLElement): void {
    this.initializeComponent(wire, element, toModifyElementComponent);
  }

  private initializeComponent<t, i, o>(wire: WireComponent<i, o>, target: i, verifyComponent: ((component: Component) => TypedComponent<t, i, o>)): o {
    const component = this.components.get(wire.name);
    if (!component) {
      throw `[quasar] Invalid component name: ${wire.name}`
    }

    const ref = wire.ref;

    const typedComponent = verifyComponent(component);
    const init = typedComponent.init({ initData: wire.data, target, componentApi: this.componentApi });

    if (ref !== null) {
      const instance = new ComponentInstance(this.client, ref, component);
      this.instances.set(ref, instance);

      const { output, unsubscribe, receive } = init.initConnected(instance.sendComponentEvent);

      if (receive) {
        instance.commandHandler = receive;
      }
      if (unsubscribe) {
        instance.addUnsubscriber(unsubscribe);
      }

      return output;
    }
    else {
      return init.initStatic();
    }

  }

  freeInstanceRef(ref: Ref) {
    const instance = this.instances.get(ref);
    if (instance) {
      instance.freeRef();
      this.instances.delete(ref);
    }
  }

  freeAllInstanceRefs() {
    for (const instance of this.instances.values()) {
      instance.freeRef();
    }
    this.instances.clear();
  }

  handleComponentCommand(ref: Ref, data: unknown) {
    const instance = this.instances.get(ref);
    if (!instance) {
      throw `[quasar] Invalid component ref ${ref}`;
    }
    const commandHandler = instance.commandHandler;
    if (commandHandler) {
      commandHandler(data);
    }
    else {
      console.error(`[quasar] Received command for component "${instance.component.name}" (${ref}) but handler is null`);
    }
  }
}

class QuasarWebClient {
  private websocketAddress: string;
  private websocket: WebSocket | null = null;
  private state: State = State.Initial;
  private closeReason: string | null = null;
  private reconnectDelay: number = 0;
  private pingInterval: ReturnType<typeof setInterval> | null = null;
  private pongTimeout: ReturnType<typeof setTimeout> | null = null;
  private elements: Map<number, HTMLElement> = new Map();

  private componentRegistry: ComponentRegistry = new ComponentRegistry(this);

  constructor(extensions: Extension[], websocketAddress?: string) {
    this.componentRegistry.registerComponents(coreComponents);
    for (const extension of extensions) {
      this.componentRegistry.registerComponents(extension.components);
    }

    if (websocketAddress == null) {
      const protocol = window.location.protocol == "https:" ? "wss" : "ws";
      this.websocketAddress = `${protocol}://${window.location.host}:${window.location.port}/ws`;
    }
    else {
      this.websocketAddress = websocketAddress;
    }

    if (window.location.protocol === "file:") {
      throw "[quasar] failed to derive websocket address from url because 'file' protocol is used";
    }

    console.log(`[quasar] websocket url: '${this.websocketAddress}'`);

    this.connect();
  }

  close(reason: string) {
    this.closeReason = reason;
    this.setState(State.Closed);
    this.websocket?.close();
  }

  getStateDescription() {
    switch (this.state) {
      case State.Initial:
        return "connecting";
      case State.Connecting:
        return "connecting";
      case State.Connected:
        return "connected";
      case State.WaitingForReconnect:
        return "reconnecting";
      case State.Reconnecting:
        return "reconnecting";
      case State.Closed:
        return this.closeReason || "disconnected";
    }
  }

  setState(state: State) {
    this.state = state;
    const stateElement = document.getElementById("quasar-web-state");
    if (stateElement) {
      stateElement.innerText = this.getStateDescription();
    }
  }

  private connect() {
    if (this.state === State.Initial || this.state === State.WaitingForReconnect) {
      console.log("[quasar] connecting...");
      this.setState(this.state === State.Initial ? State.Connecting : State.Reconnecting);
      this.websocket?.close();
      this.websocket = new WebSocket(this.websocketAddress, ["quasar-web-dev"]);

      this.websocket.onopen = _event => {
        this.setState(State.Connected);
        this.reconnectDelay = 0;
        this.pingInterval = setInterval(() => this.sendPing(), pingIntervalMs);
        console.log("[quasar] connected");
      };

      this.websocket.onclose = _event => {
        if (this.pingInterval) {
          clearInterval(this.pingInterval);
          this.pingInterval = null;
        }
        if (this.pongTimeout) {
          clearTimeout(this.pongTimeout);
          this.pongTimeout = null;
        }
        const target = document.getElementById("quasar-web-root");
        if (target) {
          target.innerHTML = "";
        }
        this.componentRegistry.freeAllInstanceRefs();
        console.debug("[quasar] cleanup complete");

        // Reconnect in case of a clean server-side disconnect.
        // (The `close`-function and the `onerror`-handler would clear the
        // `Connected`-state in case of an error, so the immediate reconnect
        // only happens when the connection is closed by the server.
        if (this.state === State.Connected) {
          this.setState(State.WaitingForReconnect);
          setTimeout(() => this.connect(), 1_000);
        }
      };

      this.websocket.onerror = (_event) => {
        if (this.state !== State.Closed) {
          this.reconnectDelay = Math.min(this.reconnectDelay + 1_000, maxReconnectDelayMs);
          this.setState(State.WaitingForReconnect);
          console.log(`[quasar] connection failed, retrying in ${this.reconnectDelay}ms`);
          setTimeout(() => this.connect(), this.reconnectDelay);
        }
      };

      this.websocket.onmessage = (event) => {
        if (typeof event.data !== "string") {
          throw "[quasar] received invalid WebSocket 'data' message type";
        }

        let parsed = null;
        try {
          parsed = JSON.parse(event.data);
          console.debug("[quasar] received:", parsed);
        }
        catch {
          console.error("[quasar] received invalid message:", event.data);
          this.close("protocol error");
          return;
        }

        this.receiveMessage(parsed);
      };

    } else {
      console.error(`[quasar].connect ignored due to invalid state:`, this.state);
    }
  }

  private send(events: Event | Event[]) {
    if (this.state === State.Connected && this.websocket !== null) {
      this.pongTimeout = setTimeout(() => this.pingFailed(), pingTimeoutMs);
      console.debug("[quasar] sending", events);
      if (!Array.isArray(events)) {
        events = [events];
      }
      this.websocket.send(JSON.stringify(events));
    }
  }

  private sendPing() {
    this.send({ fn: "ping" });
    console.debug("[quasar] ping");
  }

  public sendComponentEvent(ref: Ref, data: unknown) {
    this.send({ fn: "component", ref, data });
  }

  private pingFailed() {
    if (this.state === State.Connected) {
      this.setState(State.WaitingForReconnect);
      console.log(`[quasar] ping timeout reached`);
      setTimeout(() => this.connect(), this.reconnectDelay);
    }
  }

  private receivePong() {
    if (this.state === State.Connected && this.pongTimeout) {
      clearTimeout(this.pongTimeout);
      this.pongTimeout = null;
    }
  }

  public createNode(wireNode: WireNode): Node {
    return this.componentRegistry.initializeCreateNodeComponent(wireNode);
    //if (wireNode.type === "element") {
    //  const element = document.createElement(wireNode.tag);

    //  if (wireNode.ref !== null) {
    //    console.log(`[quasar] registering element`, wireNode.ref);
    //    this.elements.set(wireNode.ref, element);
    //  }

    //  const children = wireNode.children.map(wireNode => this.createNode(wireNode));
    //  element.replaceChildren(...children);

    //  for (let wireComponent of wireNode.components) {
    //    this.componentRegistry.initializeModifyElementComponent(wireComponent, element);
    //  }

    //  return element;
    //}
    //else {
    //  return this.componentRegistry.initializeCreateNodeComponent(wireNode);
    //}
  }

  private getElement(ref: Ref): HTMLElement {
    const element = this.elements.get(ref);
    if (!element) {
      throw `[quasar-web] Element with ref ${ref} does not exist`;
    }
    return element;
  }

  private freeRef(ref: Ref) {
    console.log(`[quasar] freeing`, ref);
    this.componentRegistry.freeInstanceRef(ref);
    this.elements.delete(ref);
  }

  private receiveMessage(commands: Command[]) {
    for (let command of commands) {
      console.log("[quasar] handling message", command);
      switch (command.fn) {
        case "pong":
          this.receivePong();
          break;
        case "root":
          const root = document.getElementById("quasar-web-root");
          if (root) {
            const element = this.createNode(command.node);
            root.replaceChildren(element);
          }
          break;
        case "insert":
          {
            const element = this.getElement(command.ref);
            const target = element.childNodes[command.i];
            if (!target) {
              throw `[quasar-web] List index ${command.i} out of bounds`;
            }
            const newNode = this.createNode(command.node);
            target.before(newNode);
          }
          break;
        case "append":
          {
            const node = this.getElement(command.ref);
            const newNode = this.createNode(command.node);
            node.append(newNode);
          }
          break;
        case "remove":
          {
            const element = this.getElement(command.ref);
            const target = element.childNodes[command.i];
            if (!target) {
              throw `[quasar-web] List index ${command.i} out of bounds`;
            }
            target.remove();
          }
          break;
        case "replace":
          {
            const element = this.getElement(command.ref);
            const nodes = command.nodes.map(node => this.createNode(node));
            element.replaceChildren(...nodes);
          }
          break;
        case "free":
          {
            this.freeRef(command.ref);
          }
          break;
        case "component":
          {
            this.componentRegistry.handleComponentCommand(command.ref, command.data);
          }
          break;
        default:
          this.close("protocol error");
          console.error("[quasar] unhandled command:", command);
      }
    }
  }
}

let globalClient: QuasarWebClient | null = null;

export function initializeQuasarWebClient(websocketAddress?: string): void {
  globalClient?.close("reinitialized");
  globalClient = new QuasarWebClient([], websocketAddress);
}
