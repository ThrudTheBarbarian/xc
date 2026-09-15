// cross_module_libuse_helper.xc — helper module for the DCE
// smoke test. Exports three functions; only `pick` is called by
// main. `unusedOne` / `unusedTwo` should be stripped to RTS stubs
// at link time under -O2+.

// `unusedOne` deliberately uses `x * 3` so this module's compile
// pulls in `u8Mul`. The manifest's `required_runtime_routines`
// line carries that requirement to the linker — without it the
// final link would see a JSR to `u8Mul` but no definition. The
// fixture is the regression guard for that propagation.
//
// Skipped as a standalone corpus sweep — no entry point; exercised only as
// the `//xtc-link:` companion of cross_module_libuse_main.
//xtc-flags: skip

u8 pick(u8 x)      { return x + 11; }
u8 unusedOne(u8 x) { return x * 3 + 1; }
u8 unusedTwo(u8 x) { return x - 7; }
