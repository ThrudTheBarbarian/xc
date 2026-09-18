// const_divide_vec.xc — reductions whose body divides by a compile-time
// constant.
//
// Division lowers to a magic multiply needing the HIGH half of a 32x32
// product, so a loop containing one could not be vectorised until the IR
// gained VMulHi. Four shapes:
//
//   T1  a multiply and two divides, the shape int_muldiv measures
//   T2  a divisor needing the add-correction, which the vectoriser DECLINES —
//       it must still compute the right answer, scalar
//   T3  a divisor with a different post-shift
//   T4  three divides in one body, to prove the magics do not share state
//
// The array is seeded from argc so nothing here is known at compile time, and
// the values run past 2^31 so a wrong magic shows up rather than cancelling.
// N is 128 — several whole vectors plus a tail — rather than anything larger.
//
// arm64 ONLY, and not because of the vector opcodes (the other targets
// simply never take this path). The expected sums are computed for seed 1,
// and `argc` is 1 natively but ZERO under the 6502 simulator, which has no
// command line — so every assertion here would disagree on xt6502 for a
// reason that has nothing to do with what is being tested. count_bytes_vec
// and sum_and_count_vec dodge this by accident: `(i * 31 + seed) & 127`
// over 4096 elements covers each residue exactly 32 times whatever the
// seed, so their totals do not move. Full-range u32 division sums do.
//xtc-flags: target=arm64
#import "Stdio.xc"
#import "Assert.xc"

#define N 128

i32 main(i32 argc, u8** argv)
    {
    Assert.reset();
    u32 a[N];
    u32 seed = (u32)argc;               // 1 with no arguments
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (i * (u32)2654435761) + seed;

    u32 s1 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s1 = s1 + ((a[i] * (u32)7) / (u32)3) + (a[i] / (u32)11);
    Assert.isEqual(s1, (u32)1356111180);

    u32 s2 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s2 = s2 + (a[i] / (u32)7);
    Assert.isEqual(s2, (u32)233305332);

    u32 s3 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s3 = s3 + (a[i] / (u32)13);
    Assert.isEqual(s3, (u32)3759829017);

    u32 s4 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        s4 = s4 + (a[i] / (u32)3) + (a[i] / (u32)5) + (a[i] / (u32)9);
    Assert.isEqual(s4, (u32)3629446762);

    Stdio.printf("DONE 4\n");
    return 0;
    }
