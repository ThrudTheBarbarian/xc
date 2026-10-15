// par_simd_buffers — a par block over `simd:` heap pointers. A captured
// `simd:` pointer is a device buffer sized from the page-aligned block it
// points into (the block's generated gpuLength asks the runtime's registry;
// par_auto_simd.xc is the same over plain pointers the runtime aligned
// unasked). On a unified-memory GPU (Metal) the block is shared in place,
// with no copy either way. The body is an integer hash chain — exact wherever it runs — and
// heavy enough per item that auto measures the GPU; the check recomputes
// every element on the CPU, so a stale or half-copied buffer shows as bad.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (1024 * 1024)
#define ROUNDS 512

i32 main(void)
{
    simd: u32* xs = new u32[SIZE];
    simd: u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)2654435761;
        ys[i] = (u32)0;
    }
    for (u32 rep in 0..6)
    {
        par chain
        {
            for (u32 i in 0..SIZE)
            {
                u32 v = xs[i] + ys[i];
                for (u32 k in 0..ROUNDS)
                    v = v * (u32)1664525 + (u32)1013904223 + i;
                ys[i] = v;
            }
        }
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
    {
        u32 y = (u32)0;
        for (u32 rep in 0..6)
        {
            u32 v = xs[i] + y;
            for (u32 k in 0..ROUNDS)
                v = v * (u32)1664525 + (u32)1013904223 + i;
            y = v;
        }
        if (ys[i] != y)
            bad = bad + (u32)1;
        sum = sum + ys[i];
    }
    Stdio.printf("aligned=%u bad=%u sum=%u\n",
                 (u32)((((u64)xs | (u64)ys) & (u64)16383) == (u64)0), bad, sum);
    delete xs;
    delete ys;
    return 0;
}
