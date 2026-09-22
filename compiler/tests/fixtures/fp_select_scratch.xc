//xtc-flags: target=arm64
// F64 Selects across a call — a SMOKE test, and deliberately labelled as one.
//
// It does NOT reproduce bug 235 and would not have caught it. That bug was the
// arm64 float Select writing d15, which is callee-saved under AAPCS64, without
// the prologue saving it: the victim was the CALLER's live double, so it needs
// the allocator to have actually homed something in d15 across the call. In a
// small program it never does — every attempt here left the doubles in d0/d1
// or in slots, and the test passed either way. The real reproduction is a
// 3000-line application.
//
// The guard for 235 is therefore not this file; it is that the back end names
// no callee-saved register (v8-v15, x19-x28) as fixed scratch. That was
// audited when the bug was fixed and is recorded in docs/bugs/235.
#use Stdio

double neg(double v, u32 c)
{
    if ((c & (u32)1) != (u32)0) v = -v;   // -> an F64 Select
    return v;
}

double sink(u32 c, double s)
{
    // Derived from a run-time value so nothing folds and the function is not
    // inlined away — the whole point is that these are live across the call.
    double a = s * (double)1.0;    double b = s * (double)2.0;
    double d = s * (double)4.0;    double e = s * (double)8.0;
    double f = s * (double)16.0;   double g = s * (double)32.0;
    double h = s * (double)64.0;   double i = s * (double)128.0;
    double j = s * (double)256.0;  double k = s * (double)512.0;
    // Every one of those is live ACROSS this call, so they fill the
    // callee-saved pool d8-d15 — and the callee used to clobber d15.
    // A loop keeps sink above the inliner's size cap, so it stays a real
    // call with real live-across-call values.
    double r = (double)0.0;
    for (u32 q = (u32)0; q < (u32)3; q++)
        r = r + neg(s * (double)1000.0, c + q) / (double)3.0;
    return a + b + d + e + f + g + h + i + j + k + r;
}

i32 main(i32 argc, u8** argv)
{
    double t = (double)0.0;
    double s = (double)argc;
    for (u32 c = (u32)0; c < (u32)4; c++) t = t + sink(c, s);
    Stdio.printf("%lld\n", (i64)t);
    return 0;
}
