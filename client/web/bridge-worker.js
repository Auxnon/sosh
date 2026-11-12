// The game's line to the page around it, in the engine's VM worker.
//
// Lua runs in the worker and can only reach out through `conn`, which is the
// browser's WebSocket. So the worker script (worker.js, as `just web-engine`
// and the Containerfile install it) imports this first, and a `conn` to the
// path /sosh-bridge gets a socket that never touches the network: what the
// game sends goes to the page's bridge.js over a BroadcastChannel named for
// this one page (the page put the name in the worker's URL, `?bridge=`), and
// what the page posts comes back as messages. Every other address is a real
// WebSocket, untouched.
//
// Without a `?bridge=` (the Android app's world view, a shared cart's page)
// this does nothing.
const bridgeId = new URL(self.location.href).searchParams.get("bridge");

if (bridgeId && typeof self.WebSocket === "function") {
  const RealWebSocket = self.WebSocket;
  const PATH = "/sosh-bridge";

  class BridgeSocket extends EventTarget {
    constructor(url) {
      super();
      this.url = url;
      this.readyState = 0;
      this.binaryType = "blob";
      this.bufferedAmount = 0;
      this.protocol = "";
      this.extensions = "";
      this.onopen = null;
      this.onmessage = null;
      this.onerror = null;
      this.onclose = null;
      this.channel = new BroadcastChannel("sosh-bridge-" + bridgeId);
      this.channel.onmessage = (e) => {
        if (this.readyState !== 1 || !e.data || e.data.to !== "game") return;
        this.fire(new MessageEvent("message", { data: String(e.data.text) }));
      };
      setTimeout(() => {
        if (this.readyState !== 0) return;
        this.readyState = 1;
        this.fire(new Event("open"));
      }, 0);
    }

    fire(e) {
      const handler = this["on" + e.type];
      if (typeof handler === "function") handler.call(this, e);
      this.dispatchEvent(e);
    }

    send(data) {
      if (this.readyState !== 1) return;
      this.channel.postMessage({ to: "page", text: String(data) });
    }

    close() {
      if (this.readyState >= 2) return;
      this.readyState = 3;
      this.channel.close();
      this.fire(new CloseEvent("close", { code: 1000, wasClean: true }));
    }
  }

  const Patched = function (url, protocols) {
    let path = null;
    try {
      path = new URL(String(url), self.location.href).pathname;
    } catch (e) {}
    if (path === PATH) return new BridgeSocket(String(url));
    return protocols === undefined ? new RealWebSocket(url) : new RealWebSocket(url, protocols);
  };
  Patched.prototype = RealWebSocket.prototype;
  Patched.CONNECTING = 0;
  Patched.OPEN = 1;
  Patched.CLOSING = 2;
  Patched.CLOSED = 3;
  self.WebSocket = Patched;
}
