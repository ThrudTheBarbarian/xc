// vec_iota_unroll.xc — a vectorised, unrolled reduction over f(i + seed):
// copy k of the body takes copy 0's lane-index vector plus k*vw, with the
// seed's add folded into copy 0's, instead of re-broadcasting i + k*vw in
// every copy (2026-11-01, call_depth). The seed comes from argc, so it is not
// a constant; the bound is not a multiple of the unrolled width either.
#import "Stdio.xc"

u32 leaf(u32 x) { return (x * (u32)3) ^ (x >> (u32)2); }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc * (u32)1000;
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)100003; i++)
        acc = acc + leaf(i + seed) + leaf(i + seed + (u32)7);
    u32 acc2 = (u32)0;
    for (u32 i = (u32)5; i < (u32)4101; i++)
        acc2 = acc2 + ((i + seed) ^ (i * (u32)2654435761));
    Stdio.printf("%u %u\n", acc, acc2);
    return 0;
    }
