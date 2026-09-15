// Regression for the parameterised-leaf inliner. Before, the
// inliner skipped any function whose prologue had the
// `PLA : STA <tmp> : ...` retaddr-save pattern (the tmp slot
// varies by model — xl: $84/$85, xt: $8B/$8C), leaving every
// parameterised leaf call as a full JSR + frame-save + prologue
// dance even at
// -O3. The new inliner walks the prologue to extract the param
// slot list, strips the retaddr-pop / param-pop / retaddr-repush
// section from the body, and at each call site rewrites the
// caller's arg PHAs as direct `STA <slot>` stores (LIFO-matched
// to the prologue's pop order).
//
// Each test block uses ≤ 4 call sites so the inliner's bloat
// cap doesn't disable it.

#import "Stdio.xc"

u8 addU8a(u8 x, u8 y)     { return x + y; }
u8 addU8b(u8 x, u8 y)     { return x + y; }
u16 addU16(u16 x, u16 y)  { return x + y; }
u16 mul3(u16 a, u16 b, u8 c) { return a * b * c; }


void main(void)
{
    // T1: single-byte args, commutative op. 4 callers of addU8a
    // — exactly at the inliner's cap, so it fires.
    u8 r1a = addU8a(3, 4);
    u8 r1b = addU8a(10, 20);
    u8 r1c = addU8a(100, 50);
    u8 r1d = addU8a(200, 55);
    if (r1a == 7 && r1b == 30 && r1c == 150 && r1d == 255) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL %u %u %u %u\n", r1a, r1b, r1c, r1d);
    }

    // T2: 2-byte args, each caller pushes 2 PHAs per arg
    u16 r2a = addU16(100, 200);
    u16 r2b = addU16(1000, 2000);
    u16 r2c = addU16(32000, 1000);
    u16 r2d = addU16(5, 7);
    if (r2a == 300 && r2b == 3000 && r2c == 33000 && r2d == 12) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL %u %u %u %u\n", r2a, r2b, r2c, r2d);
    }

    // T3: mixed-width args (u16, u16, u8), still ≤ 4 callers
    u16 r3a = mul3(2, 3, 5);
    u16 r3b = mul3(10, 4, 3);
    u16 r3c = mul3(1, 1, 1);
    u16 r3d = mul3(100, 2, 1);
    if (r3a == 30 && r3b == 120 && r3c == 1 && r3d == 200) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL %u %u %u %u\n", r3a, r3b, r3c, r3d);
    }

    // T4: a second, separate addU8b used for another 4-call test
    // block so each group stays within the inliner's 4-caller cap
    // and we exercise two independent parameterised inlinings in
    // the same compilation unit.
    u8 s1 = addU8b(1, 2);
    u8 s2 = addU8b(3, 4);
    u8 s3 = addU8b(5, 6);
    u8 s4 = addU8b(7, 8);
    if (s1 == 3 && s2 == 7 && s3 == 11 && s4 == 15) {
        Stdio.printf("T4 PASS\n");
    } else {
        Stdio.printf("T4 FAIL %u %u %u %u\n", s1, s2, s3, s4);
    }
}
