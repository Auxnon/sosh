// A lost GPU, as a last resort. Chrome (and Android's web view) may drop a
// background tab's WebGL context or WebGPU device. The engine now rebuilds
// its GPU state itself (petrichor64's src/gpu_loss.rs) and says so with
// `petrichor-gpu-lost` / `petrichor-gpu-restored` events on window; this
// only steps in if that doesn't happen: an older engine that never says it
// lost anything (the world stays black or purple, its clear colour), or one
// that said so but didn't come back within RESTORE_WAIT. Then it reloads,
// which rejoins where we stood (the server keeps it): once the context is
// back, or as soon as the page is visible again if it was lost while
// hidden. At most once a minute, so a context that keeps dying can't loop
// the page.
(function () {
  const KEY = "sosh-recovered-at";
  const RESTORE_WAIT = 20000; // ms the engine gets to come back by itself
  let lost = false;
  let engineRecovers = false; // the engine has said it handles losses
  let waiting = null;

  function reload() {
    if (engineRecovers && !lost) return; // it came back by itself
    const last = Number(sessionStorage.getItem(KEY) || 0);
    if (Date.now() - last < 60000) return;
    sessionStorage.setItem(KEY, String(Date.now()));
    location.reload();
  }

  // a loss noticed here: reload soon, unless the engine is on it
  function onLoss() {
    lost = true;
    if (engineRecovers) return;
    if (document.visibilityState === "visible") {
      // the engine's own event may come just after the browser's
      setTimeout(() => engineRecovers || reload(), 1500);
    }
  }

  window.addEventListener("petrichor-gpu-lost", () => {
    engineRecovers = true;
    lost = true;
    clearTimeout(waiting);
    waiting = setTimeout(() => {
      if (lost && document.visibilityState === "visible") reload();
    }, RESTORE_WAIT);
  });
  window.addEventListener("petrichor-gpu-restored", () => {
    engineRecovers = true;
    lost = false;
    clearTimeout(waiting);
  });

  function watch(canvas) {
    canvas.addEventListener("webglcontextlost", (e) => {
      e.preventDefault(); // so the browser may give it back
      onLoss();
    });
    canvas.addEventListener("webglcontextrestored", () => {
      if (!engineRecovers && document.visibilityState === "visible") reload();
    });
  }

  // WebGPU (the engine's first choice in a secure context) loses its device
  // instead: GPUDevice.lost resolves. Every device the engine asks for gets
  // watched; "destroyed" is a device torn down on purpose.
  if (typeof GPUAdapter !== "undefined") {
    const request = GPUAdapter.prototype.requestDevice;
    GPUAdapter.prototype.requestDevice = function (...args) {
      return request.apply(this, args).then((device) => {
        device.lost.then((info) => {
          if (info.reason !== "destroyed") onLoss();
        });
        return device;
      });
    };
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible" || !lost) return;
    if (engineRecovers) {
      // give it its chance now that it can draw again
      clearTimeout(waiting);
      waiting = setTimeout(() => lost && reload(), RESTORE_WAIT);
    } else {
      reload();
    }
  });

  // the engine adds its canvas after this runs
  const seen = new WeakSet();
  function scan() {
    for (const c of document.querySelectorAll("canvas")) {
      if (!seen.has(c)) {
        seen.add(c);
        watch(c);
      }
    }
  }
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
})();
