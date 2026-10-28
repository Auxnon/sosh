// Controllers for the web game. The engine reads gamepads in its VM, which
// runs in a worker on the web, and a worker has no Gamepad API; so the page
// reads them here and presses the game's keys on its canvas, the same keys a
// keyboard would. The Android app's world view does this natively instead
// (it can see controllers the web view can't), so this stays off there.
//
//   left stick / d-pad   walk (w a s d)        A   take the helm / let go (b)
//   right stick, LB/RB   turn the camera (q e)  B   close the bag (escape)
//   RT / LT              climb / sink at a helm X   pose, put down (g)
//   back                 ask a helper (h)       Y   bag (i)
(function () {
  if (navigator.userAgent.includes("sosh-token/")) return;

  const DEAD = 0.4;
  const BUTTONS = {
    0: "b", 1: "Escape", 2: "g", 3: "i", 4: "q", 5: "e", 6: "c", 7: " ", 8: "h",
    12: "w", 13: "s", 14: "a", 15: "d",
  };
  const KEYS = {
    w: "KeyW", a: "KeyA", s: "KeyS", d: "KeyD", q: "KeyQ", e: "KeyE",
    b: "KeyB", Escape: "Escape", g: "KeyG", i: "KeyI", c: "KeyC", " ": "Space", h: "KeyH",
  };
  const held = new Set();

  function send(key, down) {
    const target = document.querySelector("canvas") || document.body;
    const type = down ? "keydown" : "keyup";
    target.dispatchEvent(new KeyboardEvent(type, { key, code: KEYS[key], bubbles: true }));
  }

  function poll() {
    const want = new Set();
    for (const pad of navigator.getGamepads ? navigator.getGamepads() : []) {
      if (!pad || !pad.connected) continue;
      const [lx = 0, ly = 0, rx = 0] = pad.axes;
      if (ly < -DEAD) want.add("w");
      if (ly > DEAD) want.add("s");
      if (lx < -DEAD) want.add("a");
      if (lx > DEAD) want.add("d");
      if (rx < -DEAD) want.add("q");
      if (rx > DEAD) want.add("e");
      pad.buttons.forEach((b, i) => {
        if (b.pressed && BUTTONS[i]) want.add(BUTTONS[i]);
      });
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
