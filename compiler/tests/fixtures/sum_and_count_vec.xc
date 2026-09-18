// sum_and_count_vec.xc — TWO reductions over one array in one loop.
//
// The shape every recogniser refuses: the header carries three phis (the
// induction variable, a count, and a sum) where each gates on exactly two.
// Both chains read the SAME load, so they can share one vectorised loop with
// two vector accumulators rather than being split apart.
//
// This is string_scan's inner loop. Nothing else in the tree has the shape, so
// without this fixture the path has no coverage.
#import "Stdio.xc"
#import "Assert.xc"

#define N 4096

i32 main(i32 argc, u8** argv)
    {
    Assert.reset();
    u8 buf[N];
    u32 seed = (u32)argc;               // 1 with no arguments
    for (u32 i = (u32)0; i < (u32)N; i++)
        buf[i] = (u8)(((i * (u32)31) + seed) & (u32)127);

    // T1/T2: a count and a widening sum carried together.
    u32 n = (u32)0;
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        if (buf[i] == (u8)44) n = n + (u32)1;
        acc = acc + (u32)buf[i];
        }
    Assert.isEqual(n, (u32)32);
    Assert.isEqual(acc, (u32)260096);

    // T3: two sums, no count — the same multi-accumulator shape without a
    // predicate, so the two chains differ only in what they add.
    u32 s1 = (u32)0;
    u32 s2 = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        s1 = s1 + (u32)buf[i];
        s2 = s2 + (u32)1;
        }
    Assert.isEqual(s1, (u32)260096);
    Assert.isEqual(s2, (u32)4096);

    Stdio.printf("DONE 4\n");
    return 0;
    }
