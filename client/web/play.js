// A cart shared in chat, run by the web engine on a page of its own
// (/play/<key>, server/lib/sosh_web/controllers/play_controller.ex). The
// engine always loads /game.game.png and spawns /worker.js; here those
// become the shared cart and the fenced worker, and the cart is left with
// no way to talk to anything. The page's Content-Security-Policy is the real
// fence; taking WebSocket away just makes a cart's `conn` fail at once.
const cart = document.documentElement.dataset.cart;

const realFetch = window.fetch.bind(window);
window.fetch = (input, init) => {
  const url = typeof input === "string" ? input : input && input.url;
  if (url === "/game.game.png" || (url && new URL(url, location.href).pathname === "/game.game.png")) {
    return realFetch(cart, init);
  }
  return realFetch(input, init);
};

const RealWorker = window.Worker;
window.Worker = class extends RealWorker {
  constructor(url, opts) {
    const path = new URL(String(url), location.href).pathname;
    super(path === "/worker.js" ? "/play/worker.js" : url, opts);
  }
};

window.WebSocket = class {
  constructor() {
    throw new DOMException("a shared game can't connect to anything", "SecurityError");
  }
};

// Tell the page around us (the game's chat, if we're in its frame) we're up.
const { default: init } = await import("/Petrichor64.js");
await init({ module_or_path: "/Petrichor64_bg.wasm" });
if (window.parent !== window) window.parent.postMessage({ sosh: "playing" }, location.origin);
