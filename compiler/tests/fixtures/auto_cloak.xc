// auto_cloak.xc — exercises the sema cloak-safety inference and the
// `-fauto-cloak=always` codegen promotion.
//
// Compiled with `-fauto-cloak=always` on xe-family, sema's per-decl
// cloak-safety verdict promotes Default-placement decls to
// `:cloaked` (the $4000-$7FFF library segment under PORTB=$30) when:
//   - not varargs
//   - all params fit in the $B0..$BF register window
//   - locals fit in fixed ZP slots (staticFrameEligible)
//   - no inline-asm touches $89/$8A or `(SP),Y`
//   - all transitive callees are also cloak-safe
//
// `Math.pow(double, i16)` and friends are textbook cloak-safe — pure
// arithmetic via $B0..$BF, no xtc-stack pushes, no inline asm. Their
// cloaked-bracket call adds a tiny per-call overhead but moves
// substantial code out of main RAM.
//
// We intentionally exercise both the inference AND the runtime
// behaviour: the program asserts that `pow` results are correct
// regardless of placement.

#import "Stdio.xc"
#import "Math.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // pow(double, i16) — sema marks Math.pow__double_i16 as
    // cloak-safe. Result must round-trip through the bracket.
    double r1 = Math.pow((double)2.0, (i16)10);  // 1024.0
    Assert.isTrue(r1 > 1023.99);                  // T1
    Assert.isTrue(r1 < 1024.01);                  // T2

    double r2 = Math.pow((double)3.0, (i16)4);   // 81.0
    Assert.isTrue(r2 > 80.99);                    // T3
    Assert.isTrue(r2 < 81.01);                    // T4

    // pow(double, u32)
    double r3 = Math.pow((double)2.0, (u32)16);  // 65536.0
    Assert.isTrue(r3 > 65535.99);                 // T5
    Assert.isTrue(r3 < 65536.01);                 // T6

    Assert.summary();
    return;
}
