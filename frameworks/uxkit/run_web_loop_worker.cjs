// run_web_loop_worker.cjs — the WORKER half of the `web-loop` milestone: the
// generated loader's worker-side ring primitives (verbatim shapes), on top of
// the ux_web_node.js recording rig, then the module itself.  Blocking is legal
// here — that is the whole design (§3): the worker CAN Atomics.wait.
'use strict';
const { workerData, parentPort } = require('node:worker_threads');

require('./ux_web_node.js');                    // the canvas rig: xccImports.env

const ri = new Int32Array(workerData.ring);
Object.assign(globalThis.xccImports.env, {
  _xt_ring_wait: (timeoutMs) => {
    const w = Atomics.load(ri, 0);
    if (Atomics.load(ri, 1) < w) return 1;
    const r = Atomics.wait(ri, 0, w, timeoutMs < 0 ? Infinity : timeoutMs);
    return r === 'timed-out' ? 0 : 1;
  },
  _xt_ring_read: (ptr) => {
    const r = Atomics.load(ri, 1);
    if (r >= Atomics.load(ri, 0)) return -1;
    const cap = (ri.length - 8) >> 3;
    const s = 8 + (r % cap) * 8;
    const m = new Int32Array(globalThis.xcc.memory.buffer);   // per call: grow detaches
    for (let k = 0; k < 8; k++) m[((ptr >>> 0) >> 2) + k] = ri[s + k];
    Atomics.store(ri, 1, r + 1);
    return ri[s];
  },
  // §3's second blocking primitive: the strings are read out of module
  // memory HERE (nothing raw crosses a thread boundary), the request goes
  // up as a message, and the worker blocks consuming the ring until the
  // answer (type 7) falls out.  Whatever input was queued meanwhile is
  // swallowed — that is what modal means.
  _xt_req_block: (kind, a, b, c) => {
    const cstr = (p) => {
      const m = new Uint8Array(globalThis.xcc.memory.buffer);
      let e = p >>> 0; while (m[e]) e++;
      return Buffer.from(m.subarray(p >>> 0, e)).toString('latin1');
    };
    parentPort.postMessage({ uxreq: kind | 0,
                             lines: kind === 1 ? cstr(a) : '',
                             buttons: kind === 1 ? cstr(b) : '',
                             def: c & 0xff, icon: c >> 8 });
    const cap = (ri.length - 8) >> 3;
    for (;;) {
      const w = Atomics.load(ri, 0);
      const r = Atomics.load(ri, 1);
      if (r >= w) { Atomics.wait(ri, 0, w); continue; }
      const s = 8 + (r % cap) * 8;
      const t = ri[s], ans = ri[s + 1];
      Atomics.store(ri, 1, r + 1);
      if (t === 7) return ans;
    }
  },
});

require(workerData.jsPath);                     // instantiate and run main()
