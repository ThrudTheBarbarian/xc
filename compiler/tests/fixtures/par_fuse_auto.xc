// par_fuse_auto.xc — adjacent loops --par-style=auto lifts, fused into one
// block (#147): the loops are merged first and the merged loop is lifted as
// one, so the loop a demoted block falls back to is the merged loop, which
// does what the loops did one after another. Each case prints what the loops
// compute, which is the same fused or apart (-fno-par-fuse) and serially
// (--par-style=cpu); tests/par/fuse.sh checks which loops fused.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"

#define N 200003

u32 xs[N];
u32 as[N];
u32 bs[N];
u32 cs[N];

i32 main(void)
{
    for (u32 i = 0; i < N; i++) : serial
        xs[i] = i * (u32)2654435761;

    // Three elementwise loops and a sum: one block.
    u32 total = 0;
    for (u32 i in 0..N)
        as[i] = xs[i] * (u32)3 + (u32)7;
    for (u32 i in 0..N)
        bs[i] = (as[i] >> (u32)3) ^ xs[i];
    for (u32 i in 0..N)
        total = total + (bs[i] ^ as[i]);
    Stdio.printf("chain: %u\n", total);

    // A neighbour read: apart.
    for (u32 i in 1..N)
        cs[i] = bs[i] + (u32)1;
    for (u32 i in 1..N)
        as[i] = cs[i - 1] * (u32)5;
    u32 s1 = 0;
    for (u32 i = 0; i < N; i++) : serial
        s1 = s1 + as[i];
    Stdio.printf("neighbour: %u\n", s1);

    // A sum the next loop reads: apart.
    u32 m = 0;
    for (u32 i in 0..N)
        m = m + xs[i];
    for (u32 i in 0..N)
        cs[i] = xs[i] ^ m;
    u32 s2 = 0;
    for (u32 i = 0; i < N; i++) : serial
        s2 = s2 + cs[i];
    Stdio.printf("reduction: %u %u\n", m, s2);

    // Written in both, at the index: one block.
    for (u32 i in 0..N)
        cs[i] = xs[i] + (u32)11;
    for (u32 i in 0..N)
        cs[i] = cs[i] * (u32)13;
    u32 s3 = 0;
    for (u32 i = 0; i < N; i++) : serial
        s3 = s3 + cs[i];
    Stdio.printf("twice: %u\n", s3);
    return 0;
}
