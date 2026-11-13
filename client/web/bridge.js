// The web page around the game: what the game can't do from inside the
// engine. Lua can only reach out through `conn`, so the VM worker gets a
// socket that leads here instead of the network (bridge-worker.js: a `conn`
// to /sosh-bridge, over a BroadcastChannel this page names). The game
// (client/scripts/web.lua) sends its wishes on it as `sosh;key=value;...`:
//
//   play=<key>,x,y,w,h   run that shared cart (/play/<key>) in a sandboxed
//                        frame over that part of the canvas (fractions of
//                        it): the game leaves room for it in its chat
//   ticket=<t>           the open chat's share ticket (Sosh.Media.ticket):
//                        a picture dropped on the page, pasted, or picked
//                        goes there. Only lets us post pictures to that one
//                        chat for an hour; the page never sees the session
//   pick=<n>             opens the file picker each time n goes up (the
//                        game's attach button)
//   screen=<name>        the game's screen, set as <html data-sosh-screen>
//                        (in the Android app it says only this)
//
// The cart's own page fences it off from sosh (play.js and its policy); the
// frame's sandbox adds no popups, no top-level navigation, no forms.
(function () {
  const PREFIX = "sosh;";
  const ACCEPT = "image/png,image/jpeg,image/gif,image/webp,.png,.jpg,.jpeg,.gif,.webp";
  let canvas = null;
  let state = {};
  let frame = null;
  let frameKey = null;
  let ticket = null;

  function parse(alt) {
    const out = {};
    if (!alt || !alt.startsWith(PREFIX)) return out;
    for (const part of alt.slice(PREFIX.length).split(";")) {
      const i = part.indexOf("=");
      if (i > 0) out[part.slice(0, i)] = part.slice(i + 1);
    }
    return out;
  }

  // the worker the engine spawns learns which channel is ours from its URL
  const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const channel = new BroadcastChannel("sosh-bridge-" + id);
  channel.onmessage = (e) => {
    if (e.data && e.data.to === "page") apply(String(e.data.text));
  };
  const RealWorker = window.Worker;
  window.Worker = class extends RealWorker {
    constructor(url, opts) {
      const u = new URL(String(url), location.href);
      if (u.pathname === "/worker.js" && u.origin === location.origin) u.searchParams.set("bridge", id);
      super(u.pathname === "/worker.js" ? u.pathname + u.search : url, opts);
    }
  };

  function apply(text) {
    const s = parse(text);
    // which screen the game is on, for whoever holds the page (the
    // Android app's spinner waits for "world")
    if (s.screen) document.documentElement.dataset.soshScreen = s.screen;
    ticket = s.ticket || null;
    play(s.play);
    if (s.pick !== undefined && state.pick !== undefined && s.pick !== state.pick) pick();
    state = s;
  }

  // -- a shared cart over the chat

  function play(spec) {
    if (!spec) {
      if (frame) frame.remove();
      frame = null;
      frameKey = null;
      return;
    }
    const [key, x, y, w, h] = spec.split(",");
    if (!/^[A-Za-z0-9_-]+$/.test(key)) return;
    if (frameKey !== key) {
      if (frame) frame.remove();
      frame = document.createElement("iframe");
      frame.src = "/play/" + key;
      frame.title = "a shared game";
      frame.setAttribute("sandbox", "allow-scripts allow-same-origin allow-pointer-lock");
      frame.setAttribute("allow", "autoplay; gamepad");
      frame.setAttribute("referrerpolicy", "no-referrer");
      Object.assign(frame.style, {
        position: "fixed",
        border: "0",
        borderRadius: "6px",
        background: "#241E4E",
        zIndex: "10",
      });
      document.body.appendChild(frame);
      frameKey = key;
    }
    frame.dataset.rect = [x, y, w, h].join(",");
    place();
  }

  function place() {
    if (!frame || !canvas) return;
    const [x, y, w, h] = frame.dataset.rect.split(",").map(Number);
    const r = canvas.getBoundingClientRect();
    frame.style.left = r.left + x * r.width + "px";
    frame.style.top = r.top + y * r.height + "px";
    frame.style.width = w * r.width + "px";
    frame.style.height = h * r.height + "px";
  }
  window.addEventListener("resize", place);

  // -- sharing pictures and carts into the open chat

  function pick() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ACCEPT;
    input.multiple = true;
    input.onchange = () => {
      for (const f of input.files) upload(f);
    };
    input.click();
  }

  async function upload(file) {
    if (!ticket) {
      toast("Open a chat to share a picture there.");
      return;
    }
    if (file.size > 8 * 1024 * 1024) {
      toast("That's over 8 MB.");
      return;
    }
    const url = "/api/media/shared?ticket=" + encodeURIComponent(ticket) + "&name=" + encodeURIComponent(file.name || "picture");
    try {
      const r = await fetch(url, { method: "POST", body: file, headers: { "content-type": "application/octet-stream" } });
      if (!r.ok) {
        const why = (await r.json().catch(() => ({}))).error;
        toast(
          {
            bad_media: "Only png, jpeg, gif and webp pictures (and games).",
            too_big: "That's over 8 MB.",
            rate_limited: "Too many at once: wait a little.",
            expired: "Sharing timed out: reopen the chat.",
          }[why] || "Couldn't share that.",
        );
      }
    } catch (e) {
      toast("Couldn't share that: offline?");
    }
  }

  window.addEventListener("paste", (e) => {
    const files = [...(e.clipboardData ? e.clipboardData.files : [])];
    if (files.length && ticket) {
      e.preventDefault();
      files.forEach(upload);
    }
  });
  window.addEventListener("dragover", (e) => {
    if (ticket && e.dataTransfer && [...e.dataTransfer.types].includes("Files")) e.preventDefault();
  });
  window.addEventListener("drop", (e) => {
    if (!ticket || !e.dataTransfer || !e.dataTransfer.files.length) return;
    e.preventDefault();
    [...e.dataTransfer.files].forEach(upload);
  });

  let toastEl = null;
  function toast(text) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      Object.assign(toastEl.style, {
        position: "fixed",
        left: "50%",
        bottom: "24px",
        transform: "translateX(-50%)",
        background: "#FFF4D6",
        color: "#4A3B2A",
        border: "2px solid #C9A86A",
        borderRadius: "14px",
        padding: "10px 16px",
        font: "600 14px system-ui, sans-serif",
        zIndex: "20",
        pointerEvents: "none",
      });
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.style.display = "block";
    clearTimeout(toast.t);
    toast.t = setTimeout(() => (toastEl.style.display = "none"), 3500);
  }

  // the engine adds its canvas after this runs
  function scan() {
    const c = document.querySelector("canvas");
    if (!c || c === canvas) return;
    canvas = c;
    new ResizeObserver(place).observe(canvas);
    place();
  }
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
})();
