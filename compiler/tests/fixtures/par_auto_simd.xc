// par_auto_simd — a par block over PLAIN heap pointers that the runtime aligned
// unasked: a numeric array of 64 KB and more is allocated page-aligned and
// registered (par-blocks.md §3, "auto-simd"), so the block's generated
// gpuLength finds the block from the pointer and sizes it, where a plain
// pointer used to keep the block on the CPU as "an array whose size is not
// known". On a unified-memory GPU the block is shared in place, as a `simd:`
// one is. The body is an integer hash chain — exact wherever it runs — and
// heavy enough per item that auto measures the GPU; the check recomputes every
// element on the CPU, so a stale or half-copied buffer shows as bad. The
// small array is under the threshold and stays an ordinary allocation; the
// block that indexes it runs on the CPU and must still be right.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (1024 * 1024)
#define SMALL 1024
#define ROUNDS 256

u32 mix(u32 x, u32 rounds)
{
    for (u32 r in 0..rounds)
    {
        x = x ^ (x >> (u32)15);
        x = x * (u32)0x85ebca77;
        x = x ^ (x << (u32)13);
    }
    return x;
}

i32 main(void)
{
    u32* xs = new u32[SIZE];
    u32* ys = new u32[SIZE];
    u32* small = new u32[SMALL];
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)2654435761;
        ys[i] = (u32)0;
    }
    for (u32 i in 0..SMALL)
        small[i] = i;
    for (u32 rep in 0..4)
    {
        par chain
        {
            for (u32 i in 0..SIZE)
                ys[i] = ys[i] ^ mix(xs[i] + rep, ROUNDS);
        }
    }
    par tiny
    {
        for (u32 i in 0..SMALL)
            small[i] = small[i] * (u32)3 + (u32)1;
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
    {
        u32 want = (u32)0;
        for (u32 rep in 0..4)
            want = want ^ mix(xs[i] + rep, ROUNDS);
        if (ys[i] != want)
            bad = bad + (u32)1;
        sum = sum + ys[i];
    }
    u32 sbad = (u32)0;
    for (u32 i in 0..SMALL)
        if (small[i] != i * (u32)3 + (u32)1)
            sbad = sbad + (u32)1;
    Stdio.printf("bad=%u sbad=%u sum=%u\n", bad, sbad, sum);
    return (i32)0;
}
