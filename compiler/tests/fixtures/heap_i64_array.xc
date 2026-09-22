//xtc-flags: target=arm64
// `new i64[N]` and `new u64[N]` must allocate EIGHT bytes per element.
// i64/u64 were the only scalar types missing from the primitive-element list
// that decides the allocator call shape, so the lowering emitted the
// one-argument form `_xtc_new_i64(count)` while the synthesised stub read the
// two-argument form `_xtc_new_i64(count, stride)` — and the stride was
// whatever the second argument register happened to hold. docs/bugs/233.
//
// The count is large on purpose: the stub floors any allocation at 256 bytes,
// which hides a garbage stride whenever it multiplies out small.
// target=arm64: the xt6502 has no 64-bit heap array of this size.
#use Stdio

i32 main(void)
{
    u32 n = (u32)50000;

    i64* a = new i64[n];
    for (u32 i = (u32)0; i < n; i++) a[i] = (i64)i * (i64)$DEAD0001;
    i64 sa = (i64)0;
    for (u32 i = (u32)0; i < n; i++) sa = sa + a[i];

    u64* b = new u64[n];
    for (u32 i = (u32)0; i < n; i++) b[i] = (u64)i * (u64)$BEEF0003;
    u64 sb = (u64)0;
    for (u32 i = (u32)0; i < n; i++) sb = sb + b[i];

    // Both ends of each array, so an under-allocation that survives the write
    // still shows up as a wrong read rather than as silence.
    Stdio.printf("a0=%llx aN=%llx sa=%lld\n", (u64)a[0], (u64)a[n - (u32)1], sa);
    Stdio.printf("b0=%llx bN=%llx sb=%llu\n", b[0], b[n - (u32)1], sb);
    delete a;
    delete b;
    return 0;
}
