// par_pin_free_mixed — an array a GPU worker imported in place for a tiled
// run is freed, and a single-shot GPU run follows before any tiled one. RADV
// puts every memory object of the device in every submission, so an import
// left over from the freed array failed that next run ("The CS has been
// rejected", -14) and lost the device. Each round runs the heavy block on
// every device as tiles, frees its arrays, then runs a light block on the GPU
// in one launch over new arrays. The heavy block is checked on the CPU, the
// light one through its sum.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (512 * 1024)
#define ROUNDS 128

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

u32 light(u32 seed)
{
    u32* as = new u32[SIZE];
    u32* bs = new u32[SIZE];
    for (u32 i in 0..SIZE)
        as[i] = i + seed;
    par copy :device(gpu)
    {
        for (u32 i in 0..SIZE)
            bs[i] = as[i] + (u32)1;
    }
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
        sum = sum + bs[i];
    delete as;
    delete bs;
    return sum;
}

u32 round(u32 seed)
{
    u32* xs = new u32[SIZE];
    u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
    {
        xs[i] = (i + seed) * (u32)2654435761;
        ys[i] = (u32)0;
    }
    par chain :device(all)
    {
        for (u32 i in 0..SIZE)
            ys[i] = mix(xs[i], ROUNDS);
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
    {
        if (ys[i] != mix(xs[i], ROUNDS))
            bad = bad + (u32)1;
        sum = sum + ys[i];
    }
    delete xs;
    delete ys;
    if (bad != (u32)0)
        Stdio.printf("round %u: %u bad\n", seed, bad);
    return sum ^ light(seed);
}

i32 main(void)
{
    u32 total = (u32)0;
    for (u32 k in 0..6)
        total = total ^ round(k);
    Stdio.printf("%u\n", total);
    return (i32)0;
}
