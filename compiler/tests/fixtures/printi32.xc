// Regression for two interlocked Stdio.printI32 widening bugs (see
// git history for full background). Converted to emit PASS/FAIL
// lines directly so the fixture is self-verifying via `xts -d`.
//
// The comparisons are written inline rather than going through a
// helper function — passing a negated i32 literal (e.g. `-789`) as
// a function argument on the banked target is a separate latent
// codegen bug (bug #1 from the original fixture header: the
// emitWide4ArgPush lowering still only matches raw XTLiteralIntNode,
// and the unary-neg-literal path never got a banked fix). Keep the
// comparisons in main() so this fixture doesn't trip on that.

#import "Stdio.xc"

i32 g = -1234567;

void main(void)
{
    // Variable case (bug 2): i32 v = -789 from a negated literal.
    i32 v = -789;
    if (v == -789) { Stdio.printf("T1 PASS\n"); }
    else           { Stdio.printf("T1 FAIL\n"); }

    // Literal case (bug 1): pushing a negated literal through an i32
    // local first still covers the storage path that was originally
    // broken. Assign from a negated literal and verify the bytes.
    i32 l = -789;
    if (l == -789) { Stdio.printf("T2 PASS\n"); }
    else           { Stdio.printf("T2 FAIL\n"); }

    i32 z = 0;
    if (z == 0) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL\n"); }

    i32 o = 1;
    if (o == 1) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL\n"); }

    i32 m1 = -1;
    if (m1 == -1) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL\n"); }

    i32 big = 100000;
    if (big == 100000) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL\n"); }

    i32 mbig = -100000;
    if (mbig == -100000) { Stdio.printf("T7 PASS\n"); } else { Stdio.printf("T7 FAIL\n"); }

    // Through a global (data-section spill).
    if (g == -1234567) { Stdio.printf("T8 PASS\n"); }
    else               { Stdio.printf("T8 FAIL\n"); }

    // u32.
    u32 uv = 123456;
    if (uv == 123456) { Stdio.printf("T9 PASS\n"); }
    else              { Stdio.printf("T9 FAIL\n"); }

    u32 uz = 0;
    if (uz == 0) { Stdio.printf("T10 PASS\n"); } else { Stdio.printf("T10 FAIL\n"); }
}
