// run_web_loop.mjs — the Node half of the `web-loop` milestone: plays the
// MAIN THREAD's role from the generated loader (ring writer), with the module
// blocking in a worker_thread.  Same SAB layout as the loader: [0]=write seq,
// [1]=read seq, slots of 8 i32s from index 8.
//
// Usage: node run_web_loop.mjs <path/to/test_web_loop.js>
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

// Give the app time to reach its blocking nextEvent, then click the Stop
// button (window at 0,0; button at 40,40 size 80x24 -> its centre).
setTimeout(() => push(1, 80, 52, 0), 300);
// Belt and braces: if the click is somehow missed, a second one later —
// the test still checks the ACTION fired, so extra clicks cannot fake a pass.
setTimeout(() => push(1, 80, 52, 0), 1500);
// Hard stop so a wedged run fails rather than hangs.
setTimeout(() => { console.error('web-loop: timed out'); process.exit(2); }, 8000);
