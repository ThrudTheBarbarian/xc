// simd_new_aligned — `new T[n]` into a `simd:` pointer allocates PAGE-ALIGNED
// storage (par-blocks.md), in both the declaration and the assignment form,
// so a unified-memory GPU can wrap the buffer in place with no copy. The heap
// header still sits just before the payload, so `.length` reads the count as
// for any block, and `delete` frees the allocator's real base (an aligned
// block keeps that base beside its header — a wrong free would crash here).
// The 64-bit targets carry the aligned helper; the narrow ones have no GPU to
// feed and keep the plain allocation, so they are left out.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"

#define N 100000

i32 main(void)
{
    simd: u32* a = new u32[N];
    simd: u32* b;
    b = new u32[N];
    a[N - 1] = (u32)7;
    b[0] = (u32)9;
    Stdio.printf("a_aligned=%u b_aligned=%u a_len=%u b_len=%u a_last=%u b_first=%u\n",
                 (u32)(((u64)a & (u64)16383) == (u64)0), (u32)(((u64)b & (u64)16383) == (u64)0),
                 (u32)a.length, (u32)b.length, a[N - 1], b[0]);
    delete a;
    delete b;
    return 0;
}
