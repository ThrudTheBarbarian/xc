// The runtime-trip vector limit must come from the trip LENGTH, not the
// bound: M = start + (max(n - start, 0) & ~(vw-1)). Rounding the bound
// (n & ~(vw-1)) was wrong three ways, each pinned here at a runtime-opaque
// bound (fuzz seed 267 found the first):
//   1. n below the start: the remainder seeded below the start and ran a
//      zero-trip loop's body — a [2, 1) loop wrote ga0[0].
//   2. a start not a multiple of vw: the iv (start + k*vw) never equals
//      n & ~(vw-1), so the last vector step overran M and the remainder
//      re-applied the overlap — [2, 20) with vw 8 ran 16 and 17 twice.
//   3. a NEGATIVE bound with a zero start: M rounded further negative, and
//      the remainder ran [M, n) backwards from below zero.
#import "Stdio.xc"
u16 a1[8];
u16 a2[32];
u16 a3[16];
u32 ga1[16];
u8  gz[4];
void main(void)
{
    for (i16 gi = (i16)0; gi < (i16)16; gi = gi + (i16)1) { ga1[gi] = (u32)(gi * (i16)2 + (i16)6); }
    i16 z = (i16)((u16)(ga1[14] * gz[0]) % (u16)8);   // opaque runtime 0

    // 1: zero-trip loop with non-zero start (n=1 < start=2)
    for (i16 i = (i16)2; i < z + (i16)1; i = i + (i16)1) { a1[i] = (u16)(a1[i] + (u16)1); }
    // 2: misaligned start, n=20: every element in [2, 20) exactly once
    for (i16 j = (i16)2; j < z + (i16)20; j = j + (i16)1) { a2[j] = (u16)(a2[j] + (u16)1); }
    // 3: negative runtime bound, zero start
    for (i16 k = (i16)0; k < z - (i16)5; k = k + (i16)1) { a3[k] = (u16)(a3[k] + (u16)7); }

    i16 s1 = (i16)0; i16 s2 = (i16)0; i16 s3 = (i16)0;
    for (i16 m = (i16)0; m < (i16)8;  m = m + (i16)1) { s1 = s1 + (i16)a1[m]; }
    for (i16 m = (i16)0; m < (i16)32; m = m + (i16)1) { s2 = s2 + (i16)a2[m]; }
    for (i16 m = (i16)0; m < (i16)16; m = m + (i16)1) { s3 = s3 + (i16)a3[m]; }
    Stdio.printf("%d %d %d %u %u %u %u\n", s1, s2, s3, a2[1], a2[2], a2[16], a2[19]);
}
