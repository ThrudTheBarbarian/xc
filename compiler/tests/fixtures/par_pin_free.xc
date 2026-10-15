// par_pin_free — arrays a GPU runtime pinned are freed and allocated again.
// On a CUDA card the runtime registers a page-aligned block whole for its
// copies (ParCuda.pinned) and gives the block's header the unpin hook, which
// the runtime calls once when the block is freed (rt-freestanding.c), so the
// registration never outlives the memory and the next allocation at the same
// address starts clean. Elsewhere the blocks are simply freed. Every round
// allocates, runs the block, checks every element on the CPU and frees; the
// body is heavy enough per item that auto measures the GPU.
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

u32 round(u32 seed)
{
    u32* xs = new u32[SIZE];
    u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
    {
        xs[i] = (i + seed) * (u32)2654435761;
        ys[i] = (u32)0;
    }
    par chain
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
    return sum;
}

i32 main(void)
{
    u32 total = (u32)0;
    for (u32 k in 0..6)
        total = total ^ round(k);
    Stdio.printf("%u\n", total);
    return (i32)0;
}
