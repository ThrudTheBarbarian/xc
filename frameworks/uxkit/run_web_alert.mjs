// run_web_alert.mjs — the Node half of the `web-alert` gate: plays the PAGE's
// role for a modal alert.  The worker posts the request up (strings already
// decoded worker-side), this side "shows the dialog" — prints it — answers
// button 2, and pushes the type-7 reply into the ring the worker is blocking
// on.  Same SAB layout as the loader.
//
// Usage: node run_web_alert.mjs <path/to/test_web_alert.js>
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
worker.on('message', (m) => {
  if (m && m.uxreq === 1) {
    console.log(`page: alert icon=${m.icon} lines="${m.lines}" buttons="${m.buttons}" default=${m.def}`);
    push(7, 2);                       // the user picks button 2 ("Discard")
  }
});
// Hard stop so a wedged run fails rather than hangs.
setTimeout(() => { console.error('web-alert: timed out'); process.exit(2); }, 8000);
