// simd_watch — the runtime's dirty tracking for a GPU's resident copies
// (par-blocks.md §3): a page-aligned block is WATCHED (its pages read-only),
// the first host write faults and is absorbed by the runtime, and from then
// on the block reads as written until it is watched again. The fault handler
// is the whole mechanism — a write by any code at all is seen, with no help
// from the compiler — so this checks it directly: watch, read clean, write,
// read written; a second block is unaffected by the first's write; a block
// under 64 KB is no block and cannot be watched; unwatch reads as written;
// a freed block is let go. The output must be the same on every 64-bit host.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"

i32 _xtc_simd_watch(pointer p);
void _xtc_simd_unwatch(pointer p);
i32 _xtc_simd_dirty(pointer p);

i32 main(void)
{
    u32* a = new u32[65536];                      // 256 KB: aligned, registered
    u32* b = new u32[65536];
    u32* small = new u32[16];                     // an ordinary allocation
    for (u32 i in 0..65536)
    {
        a[i] = i;
        b[i] = i * (u32)3;
    }
    i32 w1 = _xtc_simd_watch((pointer)a);         // 1
    i32 w2 = _xtc_simd_watch((pointer)b);         // 1
    i32 ws = _xtc_simd_watch((pointer)small);     // 0: no block
    i32 d0 = _xtc_simd_dirty((pointer)a);         // 0: clean
    u32 r = a[4096];                              // a read does not fault
    a[4096] = r + (u32)1;                         // the write faults, once
    a[4097] = (u32)7;                             // and the block is writable again
    i32 d1 = _xtc_simd_dirty((pointer)a);         // 1: written
    i32 d2 = _xtc_simd_dirty((pointer)b);         // 0: b was not written
    small[3] = (u32)9;                            // no block: no fault
    i32 ds = _xtc_simd_dirty((pointer)small);     // 1: unknown is dirty
    i32 w3 = _xtc_simd_watch((pointer)a);         // 1: watched again
    i32 d3 = _xtc_simd_dirty((pointer)a);         // 0
    _xtc_simd_unwatch((pointer)b);
    i32 d4 = _xtc_simd_dirty((pointer)b);         // 1: not watched
    b[0] = (u32)1;                                // writable, no fault
    u32 sum = (u32)0;
    for (u32 i in 0..65536)
        sum = sum + a[i];
    delete a;                                     // watched: let go before the allocator touches it
    delete b;
    u32* c = new u32[65536];                      // likely the same pages: clean again
    i32 w4 = _xtc_simd_watch((pointer)c);         // 1
    c[0] = (u32)1;
    i32 d5 = _xtc_simd_dirty((pointer)c);         // 1
    Stdio.printf("%d %d %d %d %d %d %d %d %d %d %d %d %u\n", w1, w2, ws, d0, d1, d2, ds, w3, d3, d4, w4, d5, sum);
    return (i32)0;
}
