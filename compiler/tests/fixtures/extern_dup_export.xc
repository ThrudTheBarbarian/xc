// extern_dup_export.xc — task #31: `extern` on a definition promises the
// SPELLED name to non-xtc consumers (a wasm export label, a .so symbol a C
// caller looks up). Two extern definitions of one name would have to share
// that label, so the second is a compile error. Overload freely; export one.
//xtc-flags: expect=sema-error
extern u32 f(u32 a) { return a; }
extern u32 f(u32 a, u32 b) { return a + b; }

i32 main(void) { return 0; }
