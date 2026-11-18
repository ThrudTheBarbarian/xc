// run_web_hold.mjs — the Node half of the `web-hold` gate: the ring writer scripting
// two presses, one held still and one that moves away, with real time between the records.
// (Adapted from run_web_drag.mjs.)  Because the ring is a queue, the whole gesture goes in
// as one burst: the worker's nextEvent consumes the down and dispatches into
// UXSlider.mouseDown, whose trackDragStep loop then consumes the moves and
// the release straight off the ring — order preserved, no timing dance.
// Same SAB layout as the loader: [0]=write seq, [1]=read seq, 8-i32 slots.
//
// Usage: node run_web_drag.mjs <path/to/test_web_hold.js>
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const jsPath = path.resolve(process.argv[2]);
const ring = new SharedArrayBuffer(4096);
const i32 = new Int32Array(ring);
const cap = (i32.length - 8) >> 3;
const push = (t, a = 0, b = 0, c = 0) => {
  const w = Atomics.load(i32, 0);
  if (w - Atomics.load(i32, 1) >= cap) Atomics.add(i32, 1, 1);
  const s = 8 + (w % cap) * 8;
  i32[s] = t | 0; i32[s + 1] = a | 0; i32[s + 2] = b | 0; i32[s + 3] = c | 0;
  i32[s + 4] = 0; i32[s + 5] = 0; i32[s + 6] = 0; i32[s + 7] = 0;
  Atomics.store(i32, 0, w + 1);
  Atomics.notify(i32, 0);
};

const worker = new Worker(path.join(here, 'run_web_loop_worker.cjs'),
                          { workerData: { ring, jsPath } });
worker.on('exit', (code) => process.exit(code));
worker.on('error', (e) => { console.error(e); process.exit(1); });

const at = (ms, f) => setTimeout(f, ms);
at(300, () => push(1, 50, 40, 0));     // a press, held still past 300 ms
at(400, () => push(3, 51, 41));        // a twitch within the slop
at(900, () => push(2, 51, 41, 0));     // released
at(1100, () => push(1, 80, 40, 0));    // a press that moves away at once
at(1150, () => push(3, 120, 40));
at(1800, () => push(2, 120, 40, 0));   // released after the delay: still not held
at(6000, () => { console.error('web-hold: timed out'); process.exit(2); });
