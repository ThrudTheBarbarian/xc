// vectorize_unroll_start.xc — the reduction unroll counts the TRIP from the
// loop's start, not its bound (2026-11-01).
//
// After vectorising a reduction, the unroll runs 4 (or 2) vectors a turn when
// the trip divides evenly. It tested the BOUND: `for (r = 4; r < 64; r++)` has
// a bound that is a multiple of 16 and a trip of 60 that is not, so four
// copies ran 4 elements past the end and the sum came out 2272, not 2010, at
// -O2 on arm64, in every release since 0.86 at least. The loops sum r ^ argc
// (argc is 1 here) so that nothing folds them away. The last starts above 2^31:
// the port read that start as negative and took another path than the reference.

#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
    {
    u32 k = (u32)argc;
    u32 a = (u32)0;
    for (u32 r = (u32)4; r < (u32)64; r++)
        a = a + (r ^ k);
    u32 b = (u32)0;
    for (u32 r = (u32)8; r < (u32)72; r++)       // trip 64: four copies are right
        b = b + (r ^ k);
    u32 c = (u32)0;
    for (u32 r = (u32)24; r < (u32)64; r++)      // trip 40: two copies
        c = c + (r ^ k);
    u32 d = (u32)0;
    for (u32 r = (u32)2199999000; r < (u32)2200000000; r++)   // start above 2^31, trip 1000
        d = d + (r ^ k);
    Stdio.printf("a=%u b=%u c=%u d=%u\n", a, b, c, d);
    return (i32)0;
    }
