// Package entry point
// Reexport public api here

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
  | { fn: "text", ref: number, text: string }
  | { fn: "insert", ref: number, i: number, node: WireNode }
  | { fn: "append", ref: number, node: WireNode }
  | { fn: "remove", ref: number, i: number }
  | { fn: "removeAll", ref: number }
  | { fn: "removeAll", ref: number }
  | { fn: "free", ref: number }

// type Event =
//   | { fn: "ping" }

type WireNode =
  | { type: "element", ref: number | null, tag: string, attributes: Map<string, string>, children: [WireNode] }
  | { type: "text", ref: number | null, text: string }


class QuasarWebClient {
  private websocketAddress: string;
  private websocket: WebSocket | null = null;
  private state: State = State.Initial;
  private closeReason: string | null = null;
  private reconnectDelay: number = 0;
  private pingInterval: ReturnType<typeof setInterval> | null = null;
  private pongTimeout: ReturnType<typeof setTimeout> | null = null;
  private elements: Map<number, HTMLElement> = new Map();
  private textNodes: Map<number, Text> = new Map();

  constructor(websocketAddress?: string) {
    if (websocketAddress == null) {
      const protocol = window.location.protocol == "https:" ? "wss" : "ws";
      this.websocketAddress = `${protocol}://${window.location.host}`;
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
        console.debug(`[quasar] cleanup complete`);

        // Reconnect in case of a clean server-side disconnect.
        // (The `close`-function and the `onerror`-handler would clear the
        // `Connected`-state in case of an error, so the immediate reconnect
        // only happens when the connection is closed by the server.
        if (this.state === State.Connected) {
          this.setState(State.WaitingForReconnect);
          this.connect();
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

  private sendPing() {
    if (this.state === State.Connected && this.websocket !== null) {
      this.pongTimeout = setTimeout(() => this.pingFailed(), pingTimeoutMs);
      this.websocket.send("ping");
      console.debug("[quasar] ping");
    }
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

  private createNode(wireNode: WireNode): Node {
    if (wireNode.type == "element") {
      const element = document.createElement(wireNode.tag);

      if (wireNode.ref != null) {
        console.log(`[quasar] registering element`, wireNode.ref);
        this.elements.set(wireNode.ref, element);
      }

      const children = wireNode.children.map(wireChild => this.createNode(wireChild));
      element.replaceChildren(...children);

      return element;
    }
    else {
      const textNode = document.createTextNode(wireNode.text);

      if (wireNode.ref != null) {
        console.log(`[quasar] registering text node`, wireNode.ref);
        this.textNodes.set(wireNode.ref, textNode);
      }

      return textNode;
    }
  }

  private getElement(ref: number): HTMLElement {
    const element = this.elements.get(ref);
    if (!element) {
      throw `[quasar-web] Element with ref ${ref} does not exist`;
    }
    return element;
  }

  private getTextNode(ref: number): Text {
    const node = this.textNodes.get(ref);
    if (!node) {
      throw `[quasar-web] Text node with ref ${ref} does not exist`;
    }
    return node;
  }


  private freeRef(ref: number) {
    console.log(`[quasar] freeing`, ref);
    this.elements.delete(ref);
    this.textNodes.delete(ref);
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
        case "text":
          const element = this.getTextNode(command.ref);
          element.data = command.text;
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
        case "removeAll":
          {
            const element = this.getElement(command.ref);
            element.replaceChildren();
          }
          break;
        case "free":
          {
            this.freeRef(command.ref);
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
  globalClient = new QuasarWebClient(websocketAddress);
}
