// spike.xc — Spike 0 for the Worker+SAB run loop (wasm-target.md §12.2
// option 3, Rocks/doc/XG-WEB-BACKEND.md §3, TODO-wasm.md W3).
//
// Proves the full round trip: DOM click → main-thread ring push → the
// Worker's Atomics.wait wakes → the module reads the event out of the
// SAB into its own (non-shared) memory → a canvas draw via a #package
// host import. `main()` here BLOCKS — which is the whole point: it can,
// because it runs in a Worker; the page stays live.
//
// Build:  xcc -A wasm32 -o spike spike.xc
// Run:    python3 serve.py   then open http://localhost:8000/
//
// The ring/event contract is the loader's (see the generated spike.js
// header): _xt_ring_wait / _xt_ring_read from env, events of 8 i32s
// [type,a,b,...] with type 1 = mousedown (a=x, b=y), 4 = keydown.

// The loader's blocking ring primitives (env — the Worker side provides
// them; running this under plain Node fails at call time, by design).
extern i32 _xt_ring_wait(i32 timeoutMs);
extern i32 _xt_ring_read(i32* ev);

// The page's drawing surface, supplied by driver.js in the WORKER
// (cfg.workerScript) over the transferred OffscreenCanvas.
#package gfx
extern void clearAll(void);
extern void drawBox(i32 x, i32 y, i32 w, i32 h);

void main()
{
    i32 ev[8];
    bool running = true;
    clearAll();
    while (running) {
        _xt_ring_wait((i32)-1);                 // block until something arrives
        while (_xt_ring_read(&ev[0]) >= (i32)0) {
            if (ev[0] == (i32)1) {              // mousedown: box at the click
                drawBox(ev[1] - (i32)6, ev[2] - (i32)6, (i32)12, (i32)12);
            } else if (ev[0] == (i32)4 && ev[1] == (i32)67) {   // 'C' clears
                clearAll();
            } else if (ev[0] == (i32)4 && ev[1] == (i32)81) {   // 'Q' quits
                running = false;
            }
        }
    }
}
