// Controllers for the web game. The engine reads gamepads in its VM, which
// runs in a worker on the web, and a worker has no Gamepad API; so the page
// reads them here and presses the game's keys on its canvas, the same keys a
// keyboard would. The Android app's world view does this natively instead
// (it can see controllers the web view can't), so this stays off there.
//
//   left stick / d-pad   walk, steer (arrows)   A      take the helm / let go (b)
//   right stick, LB/RB   turn the camera (q e)  B      close what's open (escape)
//   RT / LT              climb / sink at a helm X      pose, put down (g)
//   view (back)          ask a helper (h)       Y      bag (i)
//   menu (start)         the book (o)           L3/R3  what the tool uses (z x)
//
// While the book is open its keys type into its search, so a controller only
// turns its pages (left, right) and shuts it (B, menu).
(function () {
  if (navigator.userAgent.includes("sosh-token/")) return;

  const DEAD = 0.4;
  const BUTTONS = {
    0: "b", 1: "Escape", 2: "g", 3: "i", 4: "q", 5: "e", 6: "c", 7: " ", 8: "h", 9: "o", 10: "z", 11: "x",
    12: "ArrowUp", 13: "ArrowDown", 14: "ArrowLeft", 15: "ArrowRight",
  };
  const KEYS = {
    ArrowUp: "ArrowUp", ArrowDown: "ArrowDown", ArrowLeft: "ArrowLeft", ArrowRight: "ArrowRight",
    q: "KeyQ", e: "KeyE", b: "KeyB", Escape: "Escape", g: "KeyG", i: "KeyI",
    c: "KeyC", " ": "Space", h: "KeyH", o: "KeyO", z: "KeyZ", x: "KeyX",
  };
  const IN_BOOK = new Set(["ArrowLeft", "ArrowRight", "Escape"]);
  // whether the game's book is open: it says so with host.call("book", ...)
  let book = false;
  addEventListener("call", (e) => {
    const d = e.detail || {};
    if (d.name === "book" && d.args) book = d.args[0] === "open";
  }, true);
  const held = new Set();

  function send(key, down) {
    // the engine's canvas, inside the page's <petrichor-64> (winit listens there)
    const target =
      document.querySelector("petrichor-64 canvas") || document.querySelector("canvas") || document.body;
    const type = down ? "keydown" : "keyup";
    target.dispatchEvent(new KeyboardEvent(type, { key, code: KEYS[key], bubbles: true }));
  }

  function poll() {
    let want = new Set();
    for (const pad of navigator.getGamepads ? navigator.getGamepads() : []) {
      if (!pad || !pad.connected) continue;
      const [lx = 0, ly = 0, rx = 0] = pad.axes;
      if (ly < -DEAD) want.add("ArrowUp");
      if (ly > DEAD) want.add("ArrowDown");
      if (lx < -DEAD) want.add("ArrowLeft");
      if (lx > DEAD) want.add("ArrowRight");
      if (rx < -DEAD) want.add("q");
      if (rx > DEAD) want.add("e");
      pad.buttons.forEach((b, i) => {
        if (b.pressed && BUTTONS[i]) want.add(BUTTONS[i]);
      });
    }
    if (book) {
      // menu opened it, so menu shuts it
      if (want.has("o")) want.add("Escape");
      want = new Set([...want].filter((k) => IN_BOOK.has(k)));
    }
    for (const k of held) if (!want.has(k)) { held.delete(k); send(k, false); }
    for (const k of want) if (!held.has(k)) { held.add(k); send(k, true); }
    requestAnimationFrame(poll);
  }

  // polling only starts once a controller shows up
  addEventListener("gamepadconnected", function start() {
    removeEventListener("gamepadconnected", start);
    requestAnimationFrame(poll);
  });
})();
