// test_zp_promotion_full.xc
//
// Verify that implicit promotion of narrow ZP variables (u8/i8) to wider
// types in comparisons reads the correct value (zero/sign-extended) instead
// of reading adjacent ZP bytes.
//
// The test declares consecutive locals so the ZP allocator packs them
// adjacently, then performs comparisons against every wider integer type.
// If the compiler reads beyond the variable's byte width, the adjacent
// variable corrupts the result.
//
// Also tests explicit casts and mixed-signedness comparisons.

#import "Stdio.xc"
#import "Assert.xc"

void main(void) {
    Assert.reset();

    // ── u8 promoted to wider types ─────────────────────────────────
    {
        u8 a = 42;          // ZP byte N
        u8 pad = $FF;       // ZP byte N+1 (adjacent, non-zero)
        u16 u16v = 100;
        i16 i16v = 100;

        // u8 < u16 (LHS narrow, RHS wide, same signedness)
        Assert.isTrue(a < u16v);    // T1: 42 < 100
        // u16 > u8 (RHS narrow)
        Assert.isTrue(u16v > a);    // T2: 100 > 42

        // u8 < i16 (LHS narrow, mixed signedness — u8 zero-extended)
        Assert.isTrue(a < i16v);    // T3: 42 < 100
        // i16 > u8 (RHS narrow, mixed signedness)
        Assert.isTrue(i16v > a);    // T4: 100 > 42

        // u8 == u8 (no promotion needed, but sanity)
        u8 same = 42;
        Assert.isTrue(a == same);   // T5: 42 == 42

        // u8 < u8 where adjacent is non-zero (no promotion needed)
        Assert.isTrue(a < pad);     // T6: 42 < 255
    }

    // ── i8 promoted to wider types ─────────────────────────────────
    {
        i8 neg = -5;        // ZP byte N
        u8 pad = $FF;       // ZP byte N+1 (adjacent)
        i16 i16v = -10;
        u16 u16v = 200;
        i32 i32v = -100;

        // i8 < i16 (sign-extend LHS: -5 < -10 → false)
        Assert.isFalse(neg < i16v); // T7: -5 < -10 is false

        // i8 > i16 (sign-extend LHS: -5 > -10 → true)
        Assert.isTrue(neg > i16v);  // T8: -5 > -10

        // i8 == i8 (no promotion)
        i8 same_neg = -5;
        Assert.isTrue(neg == same_neg); // T9

        // i16 > i8 (LHS wide, RHS narrow, sign-extend RHS: -10 > -5 → false)
        Assert.isFalse(i16v > neg); // T10: -10 > -5 is false

        // i8 < u16 (narrow signed LHS, wide unsigned RHS)
        // Mixed signedness — use explicit i16 cast
        Assert.isTrue(((i16)neg) < u16v); // T11: -5 < 200

        // i32 > i8 via explicit cast
        Assert.isTrue(i32v < ((i32)neg)); // T12: -100 < -5
    }

    // ── u16 promoted to u32 / i32 ──────────────────────────────────
    {
        u16 a = 40000;      // 2 ZP bytes
        u16 pad16 = $FFFF;  // 2 ZP bytes (adjacent)
        u32 u32v = 100000;

        // u16 < u32 (LHS narrow, RHS wide, same signedness)
        Assert.isTrue(((u32)a) < u32v); // T13: 40000 < 100000
        Assert.isTrue(a < 50000);       // T14: 40000 < 50000 (literal)

        // u16 vs u16 where adjacent is non-zero
        Assert.isTrue(a < pad16);       // T15: 40000 < 65535
    }

    // ── i16 promoted to i32 ────────────────────────────────────────
    {
        i16 neg = -20000;   // 2 ZP bytes
        u16 pad = $FFFF;    // 2 ZP bytes (adjacent)
        i32 i32v = -100000;

        // i16 < i32 via explicit cast
        Assert.isTrue(((i32)neg) > i32v); // T16: -20000 > -100000
    }

    // ── Explicit cast to wider type ────────────────────────────────
    {
        u8 a = 7;
        i8 neg = -3;
        u16 pad = $AAAA;    // adjacent ZP filler

        // Explicit (u16) cast should zero-extend
        u16 wide_a = (u16)a;
        Assert.isEqual(wide_a, 7);      // T17: (u16)7 == 7

        // Explicit (i16) cast of i8 should sign-extend
        i16 wide_neg = (i16)neg;
        Assert.isEqual(wide_neg, (i16)(-3));   // T18: (i16)(-3) == -3
    }

    // ── Arithmetic with promotion ─────────────────────────────────
    {
        u8 a = 200;
        u8 b = 100;
        u16 pad = $FFFF;    // adjacent ZP filler

        // u8 + u8 assigned to u16 — explicit cast to promote a
        u16 sum = (u16)a + b;
        Assert.isEqual(sum, 300);       // T19: (u16)200 + 100 == 300

        // u8 - u8 assigned to i16 — explicit cast both
        i16 diff = (i16)a - (i16)b;
        Assert.isEqual(diff, 100);      // T20: (i16)200 - (i16)100 == 100
    }

    // ── Comparison with literal (adjacent ZP filler) ──────────────
    {
        u8 x = 5;
        u8 filler = $80;    // adjacent ZP byte — high bit set
        i16 limit = 20;

        // This was the original floodFill pattern: u8 compared against
        // a wider expression. The filler ensures the adjacent ZP byte
        // is non-zero, so a misread would change the result.
        Assert.isTrue(x < limit);       // T21: 5 < 20
        Assert.isFalse(x >= limit);     // T22: 5 >= 20 is false

        // x >= 1 (literal 1 is u8, no promotion needed)
        Assert.isTrue(x >= 1);          // T23: 5 >= 1

        // u8 == u16 equality
        u8 seven = 7;
        u16 seven16 = 7;
        Assert.isTrue(seven == seven16); // T24: 7 == 7
    }

    // ── Original floodFill pattern: u8 vs subexpression ──────────
    // This was the exact bug: `u8 cy < _height - 1` where _height is
    // a 16-bit ivar. The subexpression `_height - 1` is not a simple
    // identifier, so the rhs-byte function takes the evaluation path.
    {
        u8 cy = 2;          // ZP byte N
        u8 adjacent = $AA;  // ZP byte N+1 (would be read as cy's hi byte)
        u16 height = 200;

        // Compare u8 against a subexpression (not a plain identifier)
        Assert.isTrue(cy < height - 1);     // T25: 2 < 199
        Assert.isFalse(cy >= height - 1);   // T26: 2 >= 199 is false
        Assert.isTrue(cy < height);         // T27: 2 < 200

        // Also test with an i16 subexpression
        i16 iheight = 200;
        Assert.isTrue(cy < iheight - 1);    // T28: 2 < 199
    }

    Stdio.printf("DONE 28\n");
    return;
}
