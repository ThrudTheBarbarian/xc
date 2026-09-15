// int64_unary.xc — unary minus and bitwise-not on 64-bit values, and the
// negative 64-bit LITERAL that exposed all three of the bugs below.
//
// Found by the differential fuzzer (tests/fuzz). `-1747915140643999929` used to
// be typed i32 by sema's literal-negate ladder, which stopped at i32, so it
// lowered as `Neg(U64) -> I32`: a 64-bit operand with a 32-bit result. Each
// back end mis-handled that differently — arm64 emitted `neg w10, x10` (which
// its assembler rejects), xt6502 and m68k each printed a different truncation,
// and wasm32 built a module the engine refuses — which made ONE bug look like
// four. The self-hosted sema had the missing rung all along.
//
// Fixing that uncovered two more, each real on its own:
//   · m68k Neg/Not with a 64-bit result only touched the low long.
//   · arm64 Neg/Not hardcoded a `w16` scratch, so an UNHOMED i64 negate emitted
//     `neg w16, x10`.
//
// Values go through a helper so the optimiser cannot fold the operation away
// before the back end sees it (the trap tests/fixtures/int64_ops.xc documents).
#import "Stdio.xc"

i64 gneg;

i64 negate(i64 v) { return -v; }
u64 invert(u64 v) { return ~v; }

void show(string tag, u64 v)
{
    Stdio.printf("%s %lu:%lu\n", tag, (u32)(v >> (u64)32), (u32)v);
}

void main(void)
{
    // The literal itself: a negative constant below INT32_MIN.
    gneg = -1747915140643999929;
    show("lit ", (u64)gneg);            // expect 3887999088:3227725639

    // Unary minus through a helper, so it is a real runtime Neg.
    i64 a = (i64)5000000000;            // > 32 bits, so a 32-bit negate differs
    show("neg ", (u64)negate(a));       // expect 4294967294:3589934592

    // Negating a value whose low long is ZERO is the borrow case: the low half
    // stays 0 and the high half must be a plain two's-complement negate, not
    // one-too-large (which is exactly how the m68k bug showed).
    i64 z = (i64)8589934592;            // 2^33: low long 0
    show("negz", (u64)negate(z));       // expect 4294967294:0

    u64 c = (u64)9876543210;
    show("not ", invert(c));            // expect 4294967293:3008358677

    // Double negation returns the original — a cheap self-check that the two
    // halves travel together.
    show("nneg", (u64)negate(negate(a)));   // expect 1:705032704

    return;
}
