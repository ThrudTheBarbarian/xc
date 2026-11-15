// par_array_reduce_gpu.xc — `:reduce(op h[])` over 32-bit integers, which has
// a Metal version. An array of at most 16 KB is updated in a copy each
// threadgroup keeps, with atomics, and the copies are folded into the array;
// a larger one is updated with atomics on the array itself. On the CPU each
// chunk updates a private copy, as for every array reduction.
//
// + into a local u32[256] (a copy per threadgroup), + into a global
// u32[65536] (atomics on the array), | into a local u32[128], & into a local
// u32[64] and into a global u32[8192] (identity all ones), ^ into a global
// u32[4096] (16 KB, the largest copy), + of negative values into a local
// i32[100], and a block with a scalar sum beside an array. Every array starts
// non-zero, and each result is checked against the same loop run serially.
//
//xtc-na: xt6502, m68k — par has no threads there
//xtc-warn: because it has an array reduction (:reduce(op a[])), which has no GPU version yet
#import "Stdio.xc"
#import "Par.xc"

#define N 300000

u32 keys[N];
u32 big[65536];
u32 wantBig[65536];
u32 mid[8192];
u32 wantMid[8192];
u32 flip[4096];
u32 wantFlip[4096];

u32 differ(u32* a, u32* b, u32 n)
    {
    u32 bad = (u32)0;
    for (u32 i in 0..n)
        if (a[i] != b[i])
            bad = bad + (u32)1;
    return bad;
    }

u32 sum(u32* a, u32 n)
    {
    u32 s = (u32)0;
    for (u32 i in 0..n)
        s = s + a[i] * (i + (u32)1);
    return s;
    }

i32 main(void)
    {
    u32 seed = (u32)2024;
    for (u32 i in 0..N)
        {
        seed = seed * (u32)1664525 + (u32)1013904223;
        keys[i] = seed;
        }

    u32 hist[256];
    u32 want[256];
    for (u32 b in 0..256)
        {
        hist[b] = b * (u32)3;
        want[b] = hist[b];
        }
    par hist256 :reduce(+ hist[])
        {
        for (u32 i in 0..N)
            hist[keys[i] >> (u32)24] += (u32)1;
        }
    for (u32 i in 0..N)
        want[keys[i] >> (u32)24] = want[keys[i] >> (u32)24] + (u32)1;
    Stdio.printf("+ 256: bad=%u sum=%u\n", differ(&hist[0], &want[0], (u32)256), sum(&hist[0], (u32)256));

    for (u32 b in 0..65536)
        {
        big[b] = b;
        wantBig[b] = b;
        }
    par hist64k :reduce(+ big[])
        {
        for (u32 i in 0..N)
            big[keys[i] >> (u32)16] = big[keys[i] >> (u32)16] + ((keys[i] >> (u32)4) & (u32)7);
        }
    for (u32 i in 0..N)
        wantBig[keys[i] >> (u32)16] = wantBig[keys[i] >> (u32)16] + ((keys[i] >> (u32)4) & (u32)7);
    Stdio.printf("+ 65536: bad=%u sum=%u\n", differ(&big[0], &wantBig[0], (u32)65536), sum(&big[0], (u32)65536));

    u32 ors[128];
    u32 wantOrs[128];
    for (u32 b in 0..128)
        {
        ors[b] = b << (u32)24;
        wantOrs[b] = ors[b];
        }
    par orbits :reduce(| ors[])
        {
        for (u32 i in 0..N)
            ors[(keys[i] >> (u32)9) & (u32)127] |= (u32)1 << (keys[i] & (u32)23);
        }
    for (u32 i in 0..N)
        wantOrs[(keys[i] >> (u32)9) & (u32)127] = wantOrs[(keys[i] >> (u32)9) & (u32)127] | ((u32)1 << (keys[i] & (u32)23));
    Stdio.printf("| 128: bad=%u sum=%u\n", differ(&ors[0], &wantOrs[0], (u32)128), sum(&ors[0], (u32)128));

    u32 ands[64];
    u32 wantAnds[64];
    for (u32 b in 0..64)
        {
        ands[b] = (u32)$FFFFFFFF ^ b;
        wantAnds[b] = ands[b];
        }
    par andbits :reduce(& ands[])
        {
        for (u32 i in 0..N)
            ands[keys[i] & (u32)63] &= keys[i] | (u32)$FFF0FF0F;
        }
    for (u32 i in 0..N)
        wantAnds[keys[i] & (u32)63] = wantAnds[keys[i] & (u32)63] & (keys[i] | (u32)$FFF0FF0F);
    Stdio.printf("& 64: bad=%u sum=%u\n", differ(&ands[0], &wantAnds[0], (u32)64), sum(&ands[0], (u32)64));

    for (u32 b in 0..8192)
        {
        mid[b] = (u32)$FFFFFFFF;
        wantMid[b] = (u32)$FFFFFFFF;
        }
    par andwide :reduce(& mid[])
        {
        for (u32 i in 0..N)
            mid[keys[i] >> (u32)19] = mid[keys[i] >> (u32)19] & (keys[i] | (u32)$FFFFF0F0);
        }
    for (u32 i in 0..N)
        wantMid[keys[i] >> (u32)19] = wantMid[keys[i] >> (u32)19] & (keys[i] | (u32)$FFFFF0F0);
    Stdio.printf("& 8192: bad=%u sum=%u\n", differ(&mid[0], &wantMid[0], (u32)8192), sum(&mid[0], (u32)8192));

    for (u32 b in 0..4096)
        {
        flip[b] = b * (u32)2654435761;
        wantFlip[b] = flip[b];
        }
    par xorbits :reduce(^ flip[])
        {
        for (u32 i in 0..N)
            flip[keys[i] >> (u32)20] ^= keys[i] * (u32)977;
        }
    for (u32 i in 0..N)
        wantFlip[keys[i] >> (u32)20] = wantFlip[keys[i] >> (u32)20] ^ (keys[i] * (u32)977);
    Stdio.printf("^ 4096: bad=%u sum=%u\n", differ(&flip[0], &wantFlip[0], (u32)4096), sum(&flip[0], (u32)4096));

    i32 delta[100];
    i32 wantDelta[100];
    for (u32 b in 0..100)
        {
        delta[b] = (i32)-1000;
        wantDelta[b] = (i32)-1000;
        }
    par negs :reduce(+ delta[])
        {
        for (u32 i in 0..N)
            delta[keys[i] % (u32)100] += (i32)((keys[i] >> (u32)8) & (u32)15) - (i32)9;
        }
    for (u32 i in 0..N)
        wantDelta[keys[i] % (u32)100] = wantDelta[keys[i] % (u32)100] + ((i32)((keys[i] >> (u32)8) & (u32)15) - (i32)9);
    u32 bad = (u32)0;
    for (u32 b in 0..100)
        if (delta[b] != wantDelta[b])
            bad = bad + (u32)1;
    Stdio.printf("+ i32: bad=%u delta[7]=%d\n", bad, delta[7]);

    u32 total = (u32)5;
    u32 counts[32];
    u32 wantCounts[32];
    for (u32 b in 0..32)
        {
        counts[b] = (u32)1;
        wantCounts[b] = (u32)1;
        }
    par both :reduce(+ total) :reduce(+ counts[])
        {
        for (u32 i in 0..N)
            {
            counts[keys[i] & (u32)31] += (u32)1;
            total = total + (keys[i] >> (u32)28);
            }
        }
    u32 wantTotal = (u32)5;
    for (u32 i in 0..N)
        {
        wantCounts[keys[i] & (u32)31] = wantCounts[keys[i] & (u32)31] + (u32)1;
        wantTotal = wantTotal + (keys[i] >> (u32)28);
        }
    Stdio.printf("scalar and array: bad=%u total ok=%d sum=%u\n", differ(&counts[0], &wantCounts[0], (u32)32),
                 (i32)(total == wantTotal), sum(&counts[0], (u32)32));
    return (i32)0;
    }
