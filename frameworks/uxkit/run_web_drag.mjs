// run_web_drag.mjs — the Node half of the `web-drag` gate: the ring writer
// scripting a DRAG.  Because the ring is a queue, the whole gesture goes in
// as one burst: the worker's nextEvent consumes the down and dispatches into
// UXSlider.mouseDown, whose trackDragStep loop then consumes the moves and
// the release straight off the ring — order preserved, no timing dance.
// Same SAB layout as the loader: [0]=write seq, [1]=read seq, 8-i32 slots.
//
// Usage: node run_web_drag.mjs <path/to/test_web_drag.js>
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

// Slider at (10,60,200,20), value 0: the knob sits at the left end, centre ~(16,70).  Down on the
// knob; moves that arrive apart, each its own step (the value must FOLLOW); the pointer held still
// for longer than the old 4 s wait, which must not end the drag; then a burst of 40 moves queued at
// once, which trackDragStep gathers into one step at the newest; the release; the Stop click.
const at = (ms, f) => setTimeout(f, ms);
at(300, () => push(1, 16, 70, 0));   // down on the knob
at(450, () => push(3, 40, 70));
at(600, () => push(3, 60, 70));
at(750, () => push(3, 80, 70));
// held still from here to 5300 ms
at(5300, () => {
  for (let k = 1; k <= 40; k++) push(3, 80 + k * 3, 70); // to x = 200, the far end
  push(2, 200, 70, 0);       // release
  push(1, 80, 132, 0);       // Stop
});
// Belt and braces: a late second Stop cannot fake the value/fires assertions.
at(6500, () => push(1, 80, 132, 0));
// Hard stop so a wedged run fails rather than hangs.
at(12000, () => { console.error('web-drag: timed out'); process.exit(2); });
