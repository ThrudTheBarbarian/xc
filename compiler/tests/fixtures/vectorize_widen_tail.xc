// vectorize_widen_tail.xc — WIDENING-SUM and DOT-PRODUCT loops whose trip count
// is not a whole number of vectors.
//
// These two recognisers share one applier, and both consume SIXTEEN u8 elements
// (or eight u16) per vector rather than four — so a trip that is an exact
// multiple is the rare case for them, not the common one. Before the epilogue
// they needed `N % 16 == 0`, which almost nothing satisfies: a 100-element
// widening sum did not vectorise at all.
//
// a[i] = i & 7, so the values cycle 0..7 and every sum below is checkable by
// hand: 100 = 12 whole cycles (12 * 28 = 336) + {0,1,2,3} (6) = 342.
#import "Stdio.xc"

u8 a[128];
u8 b[128];
u16 wa[128];
u16 wb[128];

// RUNTIME bounds for both shapes. These lanes are 16 wide (u8) or 8 (u16), so
// M = n & ~(vw-1) is 0 for every n below 16 — the vector loop never runs and the
// cloned scalar loop does the whole range, which is the case most likely to be
// got wrong. The dot form multiplies in the NARROW lane, which is what the
// recogniser actually matches: widening first and multiplying in 32-bit lanes
// is a different shape that no recogniser claims.
u32 wsumRT(u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + (u32)a[i];
    return s;
}

u32 dotRT(u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + (u32)(wa[i] * wb[i]);
    return s;
}

void main(void)
{
    for (u32 i = (u32)0; i < (u32)128; i = i + (u32)1) {
        a[i] = (u8)(i & (u32)7);
        b[i] = (u8)2;
    }

    // 100 = 6 vectors of 16 (96) + 4.  12 cycles of 28, then 0+1+2+3.
    u32 s100 = (u32)0;
    for (u32 i = (u32)0; i < (u32)100; i = i + (u32)1) s100 = s100 + (u32)a[i];

    // 17 = 1 vector of 16 + 1.  2 cycles of 28, then a[16] = 0.
    u32 s17 = (u32)0;
    for (u32 i = (u32)0; i < (u32)17; i = i + (u32)1) s17 = s17 + (u32)a[i];

    // 64 = 4 vectors exactly: the no-epilogue path, unchanged.  8 cycles of 28.
    u32 s64 = (u32)0;
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) s64 = s64 + (u32)a[i];

    // 9 is FEWER than one 16-lane vector: must stay scalar and still be right.
    u32 s9 = (u32)0;
    for (u32 i = (u32)0; i < (u32)9; i = i + (u32)1) s9 = s9 + (u32)a[i];

    // Dot product against a constant 2 — twice the widening sum, same tails.
    u32 d100 = (u32)0;
    for (u32 i = (u32)0; i < (u32)100; i = i + (u32)1) d100 = d100 + (u32)a[i] * (u32)b[i];

    u32 d17 = (u32)0;
    for (u32 i = (u32)0; i < (u32)17; i = i + (u32)1) d17 = d17 + (u32)a[i] * (u32)b[i];

    Stdio.printf("s100=%ld s17=%ld s64=%ld s9=%ld\n", s100, s17, s64, s9);
    Stdio.printf("d100=%ld d17=%ld\n", d100, d17);

    for (u32 i = (u32)0; i < (u32)128; i = i + (u32)1) { wa[i] = (u16)(i & (u32)15); wb[i] = (u16)3; }
    // 0 and 9 are below one 16-lane vector; 16 is exactly one; 17/63/100 have tails.
    Stdio.printf("rt=%ld %ld %ld %ld %ld %ld\n",
        wsumRT((u32)0), wsumRT((u32)9), wsumRT((u32)16),
        wsumRT((u32)17), wsumRT((u32)63), wsumRT((u32)100));
    // 0 and 5 are below one 8-lane vector; 8 is exactly one; 9/33/100 have tails.
    Stdio.printf("dt=%ld %ld %ld %ld %ld %ld\n",
        dotRT((u32)0), dotRT((u32)5), dotRT((u32)8),
        dotRT((u32)9), dotRT((u32)33), dotRT((u32)100));
}
