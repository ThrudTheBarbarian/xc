// par_resident — the same block over the same arrays, run after run, with a
// host write in between. On a CUDA card the runtime keeps a block's upload
// resident: a watched, unwritten array is not sent again (the report says
// "already on the GPU"), and the write between runs 2 and 3 is seen through
// the page fault it takes, so run 3 uploads afresh. Elsewhere every run
// copies, or shares in place. Every run is checked on the CPU: a stale
// device copy, or a missed write, shows as a bad element.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (512 * 1024)
#define ROUNDS 96

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
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)2654435761;
        ys[i] = (u32)0;
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 rep in 0..5)
    {
        if (rep == (u32)2)
            for (u32 i in 0..SIZE)                // the host changes the input
                xs[i] = xs[i] + rep;
        par chain
        {
            for (u32 i in 0..SIZE)
                ys[i] = mix(xs[i] ^ rep, ROUNDS);
        }
        for (u32 i in 0..SIZE)
        {
            if (ys[i] != mix(xs[i] ^ rep, ROUNDS))
                bad = bad + (u32)1;
            sum = sum + ys[i];
        }
    }
    Stdio.printf("bad=%u sum=%u\n", bad, sum);
    return (i32)0;
}
