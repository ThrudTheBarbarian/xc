# Spike A — foreign→xtc callback with context

Proof of the callback bridge every native toolkit needs: the OS or toolkit calls
a function pointer you registered, handing it a context word. This **works in
xtc**, with no compiler change.

- `proofshim.c`: a foreign C compilation unit (the stand-in "toolkit").
  `run_callback_n(cb, ctx, n)` invokes `cb(ctx)` `n` times.
- `proof.xc`: registers a plain xtc **free function** as the callback and
  stashes an xtc object in the `void*` context. Inside the callback it recovers
  the object by cast and dispatches a method. Seeds the object to 100, gets
  called back 5×, prints `count=105`.
- `run.sh`: builds and runs the **same** `proof.xc` on two dissimilar ABIs
  (arm64/AAPCS native, win64/Win64 under Wine); both must print `count=105`.

Why it works: xtc's `standard` calling convention is the platform C ABI for
scalar/pointer/float args (that's how it calls imported C libraries), so an xtc
free function is enterable by foreign C, and the receiver rides in the context
word as in C. Not yet built: optional sugar to bind an instance method directly
(`^self.method`).

Run: `sh tests/interop/callback-context/run.sh`
