// int64_cmp.xc — the 64-bit shapes int64_ops.xc does not reach.
//
// int64_ops covers the ARITHMETIC. Everything here is a way of MOVING or
// TESTING a 64-bit value, and every one of them was wrong on at least one
// target while int64_ops passed on all six:
//
//   * comparing two 64-bit values — m68k compared only the high long, so
//     `7 == 0` was true; arm9 compared only the low word;
//   * a 64-bit value carried round a loop by a PHI — arm9 copied four bytes
//     of the eight, so a `u64` loop counter kept the frame's stack poison in
//     its high half and the loop never terminated;
//   * widening a SIGNED narrow value into 64 bits — arm64 scratched it
//     through a `w` register, so `(i64)-5` read back as 4294967291 and, once
//     spilled at four bytes and reloaded at eight, took the neighbouring
//     slot as its top word.
//
// Printed as two 32-bit halves because %ld is the widest specifier.
#import "Stdio.xc"

i64 asI64(i64 v)  { return v; }          // opaque: keeps the optimiser off
u64 asU64(u64 v)  { return v; }

// Every comparison, through a non-constant helper so none of them folds.
u32 cmp(i64 a, i64 b, u8 which)
{
    if (which == (u8)0) return (a <  b) ? (u32)1 : (u32)0;
    if (which == (u8)1) return (a >  b) ? (u32)1 : (u32)0;
    if (which == (u8)2) return (a <= b) ? (u32)1 : (u32)0;
    if (which == (u8)3) return (a >= b) ? (u32)1 : (u32)0;
    if (which == (u8)4) return (a == b) ? (u32)1 : (u32)0;
    return (a != b) ? (u32)1 : (u32)0;
}

u32 ucmp(u64 a, u64 b, u8 which)
{
    if (which == (u8)0) return (a <  b) ? (u32)1 : (u32)0;
    if (which == (u8)1) return (a >  b) ? (u32)1 : (u32)0;
    if (which == (u8)2) return (a <= b) ? (u32)1 : (u32)0;
    if (which == (u8)3) return (a >= b) ? (u32)1 : (u32)0;
    if (which == (u8)4) return (a == b) ? (u32)1 : (u32)0;
    return (a != b) ? (u32)1 : (u32)0;
}

void row(string tag, i64 a, i64 b)
{
    Stdio.printf("%s %ld%ld%ld%ld%ld%ld\n", tag,
        cmp(a,b,(u8)0), cmp(a,b,(u8)1), cmp(a,b,(u8)2),
        cmp(a,b,(u8)3), cmp(a,b,(u8)4), cmp(a,b,(u8)5));
}

void urow(string tag, u64 a, u64 b)
{
    Stdio.printf("%s %ld%ld%ld%ld%ld%ld\n", tag,
        ucmp(a,b,(u8)0), ucmp(a,b,(u8)1), ucmp(a,b,(u8)2),
        ucmp(a,b,(u8)3), ucmp(a,b,(u8)4), ucmp(a,b,(u8)5));
}

// A 64-bit value carried round a loop: `v` is a PHI on the back edge, and it
// must lose its high half or this never ends.
u32 digits(u64 v)
{
    u32 n = (u32)0;
    while (v > (u64)0) { v = v / (u64)10; n = n + (u32)1; }
    return n;
}

i32 main(void)
{
    // Signed. The last two differ only ABOVE bit 32, so a 32-bit compare
    // cannot tell them apart.
    row("s_2_0 ", asI64((i64)2), asI64((i64)0));
    row("s_0_2 ", asI64((i64)0), asI64((i64)2));
    row("s_2_2 ", asI64((i64)2), asI64((i64)2));
    row("s_n5_2", asI64((i64)0 - (i64)5), asI64((i64)2));
    row("s_hi_1", asI64((i64)1 << (i64)40), asI64((i64)1));
    row("s_hi_h", asI64((i64)1 << (i64)40), asI64((i64)2 << (i64)40));

    // Unsigned, including a value whose top bit is set — signed conditions
    // would call it negative.
    urow("u_2_0 ", asU64((u64)2), asU64((u64)0));
    urow("u_hi_1", asU64((u64)1 << (u64)40), asU64((u64)1));
    urow("u_top ", asU64((u64)1 << (u64)63), asU64((u64)1));

    // Signed widening from a narrow negative.
    Stdio.printf("sext  %ld:%ld\n", (u32)((u64)asI64((i32)0 - (i32)5) >> (u64)32),
                                    (u32)asI64((i32)0 - (i32)5));

    // Loop-carried 64-bit phi.
    Stdio.printf("dig   %ld %ld %ld\n", digits((u64)7), digits((u64)1234),
                                        digits((u64)1 << (u64)40));
    return 0;
}
