// double_to_int64.xc — bug 173. Converting a double to a 64-bit integer must
// keep all 64 bits. The arm64 FpToSI/FpToUI codegen range-checks the fcvtz
// result by re-extending its low 32 BITS and comparing — a check that only
// makes sense for a destination NARROWER than 64 bits. For an i64/u64
// destination it wrongly csel'd every value above 2^32 to 0, and separately
// stored only the low 32 bits (w16 instead of x16). Both halves are fixed here.
//
// xt6502 had the same shape through MECH: every conversion went through i32,
// so an i64 source lost its high half, an i64/u64 destination read four stale
// bytes, and a narrow destination wrapped instead of giving 0 (bug 264).
//
// Uses binary64 sources only — a `d`-suffixed literal or a widened integer —
// because an UNSUFFIXED float literal is binary32 by language design (float is
// the default; double is opt-in via `1.5d`, docs/double.md), which would lose
// precision before the conversion even runs.

#import "Stdio.xc"

i32 main(void)
{
    i32 ok = (i32)0;

    // From a widened integer (exact in binary64), above 2^32.
    i64 n = 12345678900;
    double r = (double)n;
    if ((u64)r == (u64)12345678900) ok = ok + (i32)1;   // was 0 (low-32 csel)
    if ((i64)r == (i64)12345678900) ok = ok + (i32)1;   // was 0

    // A d-suffixed literal (real binary64) that fits u32 but not i32 range:
    // (u64) was fine before, (i64) sign-extended the low 32 bits to 0.
    double q = 3000000000.5d;
    if ((u64)q == (u64)3000000000) ok = ok + (i32)1;
    if ((i64)q == (i64)3000000000) ok = ok + (i32)1;    // was 0

    // Narrower destinations still saturate out-of-range to 0 (unchanged).
    double big = 5000000000.5d;                          // > u32 max
    if ((u32)big == (u32)0) ok = ok + (i32)1;            // out of u32 range -> 0
    if ((i32)big == (i32)0) ok = ok + (i32)1;            // out of i32 range -> 0

    // In-range narrow still converts.
    double small = 2000000000.5d;
    if ((i32)small == (i32)2000000000) ok = ok + (i32)1;

    Stdio.printf("ok %d/7\n", ok);
    return (i32)0;
}
