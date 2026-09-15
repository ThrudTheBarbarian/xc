// A ternary whose arms are a bool-returning CALL and an i64 COMPARISON.
//
// sema used to type a comparison as the widening of its OPERANDS, so
// `(hi - 4) < (4 - lo)` on two i64s was an i64 node. The ternary then took
// union(bool, i64) = i64, widened the call arm with a ZExt and left the
// comparison arm alone — it already believed it was i64 — producing a phi
// with an i64 result and a Bool incoming. Untyped machines ran it anyway;
// wasm validates, and refused to instantiate the module. Reported from the
// field on wasm32, so the fixture checks the VALUES on every target rather
// than just that it builds.
#import "Stdio.xc"

i64 gA[4];

bool viaCall(i64 k) { return gA[k] > (i64)0; }

i64 pick(i64 k, i64 lo, i64 hi)
{
    bool up = (k != (i64)0) ? viaCall(k) : ((hi - (i64)4) < ((i64)4 - lo));
    i64 r = lo;
    if (up) r = hi;
    return r;
}

i32 main()
{
    gA[1] = (i64)7;         // viaCall(1) -> true
    gA[2] = (i64)0;         // viaCall(2) -> false
    // k != 0 : the CALL arm decides.
    Stdio.printf("%ld %ld\n", (i32)pick((i64)1, (i64)10, (i64)20), (i32)pick((i64)2, (i64)10, (i64)20));
    // k == 0 : the COMPARISON arm decides. (hi-4) < (4-lo)
    //   lo=10 hi=20 -> 16 < -6  false -> 10
    //   lo=-30 hi=1 -> -3 < 34  true  -> 1
    Stdio.printf("%ld %ld\n", (i32)pick((i64)0, (i64)10, (i64)20), (i32)pick((i64)0, (i64)-30, (i64)1));
    // The same shape with the arms swapped, and with && / || as an arm.
    bool b = (gA[1] != (i64)0) ? ((gA[1] < (i64)9) && viaCall((i64)1)) : viaCall((i64)2);
    Stdio.printf("%d\n", b ? 1 : 0);
    return 0;
}
