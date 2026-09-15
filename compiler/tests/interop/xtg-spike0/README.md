# Spike 0 — cross-`.so` override / weak / struct on the desktop hosts

The multi-host GUI design rests on a **library reaching an app-subclass's
override across the shared object**, plus the supporting mechanisms (optional
protocol method via a bound-method pointer, weak-zeroing when the target dies,
struct by-value both directions). These are proven on the A9 via
`libtable`/`libdemo`; this is the GEM-free port, so the same guarantees are
verified on the desktop hosts natively, without the XTOS loader.

- `xgspike_lib.xc`: built with `--emit-lib`. `LibView.render()` calls the virtual
  `drawRect` an app subclass overrides; `LibControl` stores a nullable `weak:` bound
  method and fires it; `LibGeom` passes/returns an 8-byte struct by value.
- `xgspike_app.xc`: `#import`s the lib, subclasses `LibView`, overrides `drawRect`,
  binds `&gCtl.check` as the optional method, drops the target, and exercises structs.
- `run.sh`: builds and runs the **same** app on arm64 (native), win64 (Wine), and
  x86_64 (over ssh to `XTC_X86_HOST` from `build.env`, falling back to
  `XTC_LINUX_HOST`; skipped when unreachable). All must print the
  `expected.out` lines.

Run: `sh tests/interop/xtg-spike0/run.sh`

## What it covers

An imported method is always vtable-dispatched, whereas a local call
devirtualises to a direct `Call`. Across a `.so`, then, a 16-byte bound-method
`^` argument and an 8-byte struct go through `XTIROpVTblDispatch`. The arm64 and
x86_64 backends (`XTArm64Backend`/`XTX86_64Backend`) must expand aggregate
arguments to `ceil(size/8)` registers and copy a >8-byte aggregate return from
`x0:x1` / `rax:rdx`. If only one register is marshalled per argument, the bound
method loses its code word (a `_xtc_weak_register` crash on arm64/x86_64) and
the struct loses its upper half on arm64 (`area=0`, `unit=1,2,0,0`), while the
`override=105` gate still passes.
