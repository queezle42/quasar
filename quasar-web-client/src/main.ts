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
  | { fn: "root", html: string }
  | { fn: "splice", id: number, html: string }

class QuasarWebClient {
  private websocketAddress: string;
  private websocket: WebSocket | null = null;
  private state: State = State.Initial;
  private closeReason: string | null = null;
  private reconnectDelay: number = 0;
  private pingInterval: ReturnType<typeof setInterval> | null = null;
  private pingTimeout: ReturnType<typeof setTimeout> | null = null;

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
      this.websocket = new WebSocket(this.websocketAddress, ["quasar-web-v1"]);

      this.websocket.onopen = (_event) => {
        this.setState(State.Connected);
        this.reconnectDelay = 0;
        this.pingInterval = setInterval(() => this.sendPing(), pingIntervalMs);
        console.log("[quasar] connected");
      };

      this.websocket.onclose = (_event) => {
        if (this.pingInterval) {
          clearInterval(this.pingInterval);
          this.pingInterval = null;
        }
        if (this.pingTimeout) {
          clearTimeout(this.pingTimeout);
          this.pingTimeout = null;
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

        if (event.data === "pong") {
          this.receivePong();
          return;
        }

        try {
          const parsed = JSON.parse(event.data);
          console.log("[quasar] received:", parsed);
          this.receiveMessage(parsed);
        }
        catch {
          console.error("[quasar] received invalid message:", event.data);
          this.close("protocol error");
        }
      };

    } else {
      console.error(`[quasar].connect ignored due to invalid state:`, this.state);
    }
  }

  private sendPing() {
    if (this.state === State.Connected && this.websocket !== null) {
      this.pingTimeout = setTimeout(() => this.pingFailed(), pingTimeoutMs);
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
    if (this.state === State.Connected && this.pingTimeout) {
      clearTimeout(this.pingTimeout);
      this.pingTimeout = null;
    }
  }

  private receiveMessage(commands: Command[]) {
    for (let command of commands) {
      switch (command.fn) {
        case "root":
          const root = document.getElementById("quasar-web-root");
          if (root) {
            root.innerHTML = command.html;
          }
          break;
        case "splice":
          const splice = document.getElementById("quasar-splice-" + command.id);
          if (splice) {
            splice.innerHTML = command.html;
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
