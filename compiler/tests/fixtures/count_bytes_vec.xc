// count_bytes_vec.xc — a predicated count over a BYTE array.
//
// The shape the count vectoriser refused: `if (buf[i] == k) n++` where buf is
// u8. It was restricted to 32-bit lanes because a u8 accumulator overflows —
// 8192 elements over 16 lanes is 512 increments against a 255 ceiling — so the
// mask has to be widened (u8 -> u16 -> u32) before it accumulates.
//
// Nothing in the benchmark suite counts over bytes, so without this fixture the
// path has no coverage at all: the checksum sweep cannot see it and `make test`
// does not reach it.
//
// The data is seeded from argc so the loop cannot fold to a constant, and the
// expected count is computed by the same rule the loop uses.
#import "Stdio.xc"
#import "Assert.xc"

#define N 4096

i32 main(i32 argc, u8** argv)
    {
    Assert.reset();
    u8 buf[N];
    u32 seed = (u32)argc;               // 1 when run with no arguments
    for (u32 i = (u32)0; i < (u32)N; i++)
        buf[i] = (u8)(((i * (u32)31) + seed) & (u32)127);

    // T1: count one byte value. (i*31 + 1) & 127 hits 44 exactly 32 times
    // over 4096 elements, since 31 is odd and the period is 128.
    u32 n = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        if (buf[i] == (u8)44) n = n + (u32)1;
    Assert.isEqual(n, (u32)32);

    // T2: a second count in its own loop, different value, so the widening
    // ladder is exercised twice with different masks.
    u32 m = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        if (buf[i] == (u8)0) m = m + (u32)1;
    Assert.isEqual(m, (u32)32);

    // T3: the count must survive when it is NOT the whole loop body — a
    // narrow compare against a wider bound.
    u32 hi = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        if (buf[i] > (u8)100) hi = hi + (u32)1;
    Assert.isEqual(hi, (u32)864);

    Stdio.printf("DONE 3\n");
    return 0;
    }
