// spilled_compound_assign.xc — `i += 2` etc. on a spilled u8
// local. Pre-fix the in-place fast path stored A unconditionally
// to the spill label, dropping the +=/-=/&=/|=/^= operation: the
// codegen for `i += 2` evaluated the RHS (`2`) into A and wrote
// it straight to `_spill_i`, so the loop counter snapped back to
// 2 every iteration and the loop never terminated. Forcing the
// synthesis path (`i = i + i_op_rhs`) re-emits through the
// binary-expr codegen, which loads the LHS, applies the op, and
// writes the result.
//
// Each test exercises one compound op on a spilled u8 local. The
// `vols[]` heap array forces ZP pressure so a, b, c, d, e all
// land in spill memory.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ZP-pressure scaffolding: 8 u16 locals + a heap pointer
    // push the test counters out of ZP. The only loads that
    // matter are at the asserts at the end.
    u16 p0 = 1; u16 p1 = 2; u16 p2 = 3; u16 p3 = 4;
    u16 p4 = 5; u16 p5 = 6; u16 p6 = 7; u16 p7 = 8;
    u16* vols = new u16[4];
    vols[0] = p0; vols[1] = p1; vols[2] = p2; vols[3] = p3;

    // u8 a, intentionally spilled. += inside a loop is the
    // historical break — pre-fix a stayed at 2 every iteration
    // and the loop never terminated.
    u8 a = 0;
    u8 cnt = 0;
    while (a < 10) {
        a += 2;
        cnt = cnt + 1;
        if (cnt > 20) break;   // safety: cap if the bug recurs
    }
    Assert.isEqual((u16)a, 10);    // T1
    Assert.isEqual((u16)cnt, 5);   // T2

    // -= on a spilled u8.
    u8 b = 20;
    b -= 3;
    Assert.isEqual((u16)b, 17);    // T3
    b -= 7;
    Assert.isEqual((u16)b, 10);    // T4

    // &=, |=, ^= each round-trip through the same spilled-label
    // store.
    u8 c = $F0;
    c &= $33;
    Assert.isEqual((u16)c, $30);   // T5

    u8 d = $0F;
    d |= $50;
    Assert.isEqual((u16)d, $5F);   // T6

    u8 e = $AA;
    e ^= $FF;
    Assert.isEqual((u16)e, $55);   // T7

    // Counter loop that mirrors the user's gfx.xc repro: u8
    // counter spilled, increment by 2 in the for-update slot.
    u8 reached = 0;
    for (u8 i = 5; i < 13; i += 2) {
        reached = reached + 1;
        if (reached > 10) break;
    }
    Assert.isEqual((u16)reached, 4);  // T8 — i=5,7,9,11

    // Vols only exists to maintain ZP pressure; touch it so
    // ARC doesn't decide to release-and-elide before the asserts.
    Assert.isEqual(vols[0], 1);    // T9

    Stdio.printf("DONE 9\n");
    return;
}
