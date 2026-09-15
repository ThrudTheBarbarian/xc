// vectorize_count_tail.xc — COUNT reductions whose trip count is not a whole
// number of vectors.
//
// `for (i<N) if (a[i] == k) n++` reaches the vectoriser already if-converted to
// a Select, so its body is one block and it can take the same cloned-tail
// epilogue as the map and reduction shapes.
//
// ga[i] = i & 3, so the predicate `== 2` matches exactly the i congruent to 2
// mod 4 and every expected count below is checkable by hand: in [0, 63) those
// are 2, 6, ... 62 — sixteen of them.
#import "Stdio.xc"

u32 ga[128];

void main(void)
{
    for (u32 i = (u32)0; i < (u32)128; i = i + (u32)1) ga[i] = i & (u32)3;

    // 63 = 15 vectors of 4 + 3.
    u32 c63 = (u32)0;
    for (u32 i = (u32)0; i < (u32)63; i = i + (u32)1) if (ga[i] == (u32)2) c63 = c63 + (u32)1;

    // 7 = 1 vector + 3.  Matches at i = 2 and i = 6.
    u32 c7 = (u32)0;
    for (u32 i = (u32)0; i < (u32)7; i = i + (u32)1) if (ga[i] == (u32)2) c7 = c7 + (u32)1;

    // 5 = 1 vector + 1.  Matches at i = 2 only.
    u32 c5 = (u32)0;
    for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1) if (ga[i] == (u32)2) c5 = c5 + (u32)1;

    // 3 is fewer than one vector: stays scalar, and must still be right.
    u32 c3 = (u32)0;
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) if (ga[i] == (u32)2) c3 = c3 + (u32)1;

    // 64 = 16 vectors exactly: the no-epilogue path, unchanged.
    u32 c64 = (u32)0;
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) if (ga[i] == (u32)2) c64 = c64 + (u32)1;

    Stdio.printf("c63=%ld c7=%ld c5=%ld c3=%ld c64=%ld\n", c63, c7, c5, c3, c64);
}
