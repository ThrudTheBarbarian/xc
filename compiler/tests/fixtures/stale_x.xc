// Regression for the u16-literal-assignment stale-X bug.
//
// `y = 10 + 20` folded to a u8-width constant (both operands are
// u8-fitting literals), so the emitWideBinaryExpr fallback
// called emitExprToA which produced just `LDA #$1E`. The store
// loop then emitted `STX y+1` on top of whatever X happened to
// hold from the prior wide assignment — for `x = $FF00; y = 10
// + 20;` the $FF leaked into y's high byte and y came back as
// 65310 instead of 30.
//
// The fix synthesises the upper bytes from the destination
// width before the store, via the same
// emitWideStoreExtensionForRHS helper the plain assignment path
// already uses for narrow-RHS widening.

#import "Stdio.xc"

void main(void)
{
    u16 x;
    u16 y;
    i16 s;

    x = $FF00;        // pollute X with $FF
    y = 5;            // bare literal (baseline — should already widen)
    if (y == 5) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL y=%u\n", y); }

    x = $FF00;
    y = 10 + 20;      // u8-folded constant expression
    if (y == 30) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL y=%u\n", y); }

    x = $FF00;
    y = 100 + 50;     // fits u8, wider destination
    if (y == 150) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL y=%u\n", y); }

    x = $AA00;
    y = 7 * 6;        // u8-foldable multiplication
    if (y == 42) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL y=%u\n", y); }

    x = $FF00;
    y = 200 & $F0;    // u8 bitwise op
    if (y == 192) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL y=%u\n", y); }

    // Signed destination with a u8-foldable negative: previously
    // widened to $00xx, now reaches the runtime fill and picks up
    // $FF for negatives too.
    s = $FF00;
    s = -(5 + 3);
    if (s == -8) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL s=%d\n", s); }
}
