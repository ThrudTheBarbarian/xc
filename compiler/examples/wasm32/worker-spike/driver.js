// driver.js — runs INSIDE the Worker (cfg.workerScript): defines the
// `gfx` package over the OffscreenCanvas the loader received from the
// page. This is the seam the real Xtg web driver plugs into.
const ctx = globalThis.xccCanvas ? globalThis.xccCanvas.getContext("2d") : null;
globalThis.xccImports = {
  gfx: {
    clearAll: () => {
      if (!ctx) return;
      ctx.fillStyle = "#1e1e1e";
      ctx.fillRect(0, 0, globalThis.xccCanvas.width, globalThis.xccCanvas.height);
    },
    drawBox: (x, y, w, h) => {
      if (!ctx) return;
      ctx.fillStyle = "#4ec9b0";
      ctx.fillRect(x, y, w, h);
    },
  },
};
