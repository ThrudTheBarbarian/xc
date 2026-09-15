// Regression for `(u16)u8` / `(i16)i8` / `(u32)u8` / `(i32)i8`
// cast widening.
//
// emitExprToA's XTCastExprNode case used to just evaluate the
// operand and return — no width adjustment, so a `(u16)a` where
// `a` is u8 left A=$a and X stale. Any consumer that read the
// result as a 16-bit pair (an assignment to a u16 local, an
// arithmetic operand, a call/printf arg) picked up garbage in
// the high byte: `u16 d = (u16)a;` came back as $XX00|$00C8 with
// $XX = whatever was in X.
//
// Fix: after evaluating the operand, route through
// `emitWideStoreExtensionForRHS` with the cast's target width so
// signedness is honoured (signed narrow → CMP/BCC sign-extend,
// unsigned narrow → LDX #\$00, and u32 / i32 destinations also
// fill _u32HiReg).

#import "Stdio.xc"

void main(void)
{
    u8 u = 200;
    i8 s = -5;
    u16 a;
    i16 b;
    u32 c;
    i32 d;

    a = (u16)u;
    if (a == 200) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL a=%u\n", a); }

    b = (i16)s;
    if (b == -5) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL b=%d\n", b); }

    c = (u32)u;
    if (c == 200) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL c=%lu\n", c); }

    d = (i32)s;
    if (d == -5) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL d=%ld\n", d); }

    // Cast inside arithmetic — the cast's high byte is consumed by
    // the next operator so any stale X carries straight through.
    a = (u16)u + 100;
    if (a == 300) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL a=%u\n", a); }

    // Local declaration with a cast initialiser — a different
    // codepath through emitLocalVarDecl's generic else branch.
    u16 e = (u16)u;
    if (e == 200) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL e=%u\n", e); }

    // Cast straight into a printf arg slot.
    Stdio.printf("T7 v=%u\n", (u16)u);
}
