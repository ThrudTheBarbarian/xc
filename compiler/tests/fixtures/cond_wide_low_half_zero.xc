// cond_wide_low_half_zero.xc — bug 293. A value used as a condition is true
// when any of its bits is set. arm64 tested a branch or select condition in a
// 32-bit register, so an i64 of 1 << 32, or a pointer whose low 32 bits are
// zero, read as false. Each form is tested: if, !x, a materialised !x, && and
// ||, both as a branch and as a value, the ternary, while and for.
//
// The right side of && and || converted to bool by keeping its low byte, so
// there a u16 of 256, an i64 of 1 << 32, a pointer whose low byte is zero or a
// float of 0.5 read as false on every target. m68k tested an i64 condition by
// its high long, arm9 by its low word, x86_64 and win64 by the low 32 bits,
// and wasm32 built a module that did not validate. A float condition was
// tested by its bits, so -0.0 was true, and arm64 tested a double's low 32
// bits, so 0.5 was false.
//
// The pointer is never dereferenced. Its low half is zero: 32 bits on a 64-bit
// target, 16 on a 32-bit one, and its low byte on xt6502.

#import "Stdio.xc"

u16 gOne = (u16)1;
u16 gZero = (u16)0;
#if ARCH_6502
u8 gBuf[512];
#endif

u16 condI64(i64 v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

u16 condU64(u64 v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

u16 condPtr(u8* v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

u16 condU16(u16 v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

u16 condFloat(float v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

u16 condDouble(double v)
{
    u16 r = (u16)0;
    if (v) r = r + (u16)1;
    if (!v) r = r + (u16)2;
    bool b = !v;
    if (b) r = r + (u16)4;
    if (v && gOne) r = r + (u16)8;
    if (gZero || v) r = r + (u16)16;
    r = r + (v ? (u16)32 : (u16)0);
    while (v) { r = r + (u16)64; break; }
    for (; v;) { r = r + (u16)128; break; }
    bool c = v && gOne;
    if (c) r = r + (u16)256;
    bool d = gZero || v;
    if (d) r = r + (u16)512;
    return r;
}

// A select whose condition is the wide value itself.
u16 pickI64(i64 v, u16 a, u16 b) { return v ? a : b; }
u32 pickU32(u64 v) { return v ? (u32)7 : (u32)9; }

void main(void)
{
    i64 one = (i64)1;
    i64 hi = one << 32;
    i64 neg = (i64)0 - hi;
    u64 top = (u64)1 << 63;
    Stdio.printf("i64 hi %u\n", condI64(hi));
    Stdio.printf("i64 neg %u\n", condI64(neg));
    Stdio.printf("i64 one %u\n", condI64(one));
    Stdio.printf("i64 zero %u\n", condI64((i64)0));
    Stdio.printf("u64 top %u\n", condU64(top));
    Stdio.printf("u64 hi %u\n", condU64((u64)hi));
    Stdio.printf("u64 low %u\n", condU64(((u64)1 << 32) - (u64)1));
    Stdio.printf("u64 zero %u\n", condU64((u64)0));

#if ARCH_6502
    // A banked pointer is null by its two address bytes (bug 272): one whose
    // low byte is zero.
    u8* p0 = &gBuf[0];
    u16 off = (u16)(256 - (u16)((u32)(pointer)p0 & (u32)$FF));
    u8* p = &gBuf[off & (u16)$FF];
#else
    // Read from an integer of the pointer's own width.
    u64 c64 = (u64)1 << 32;
    u32 c32 = (u32)1 << 16;
    u8* p = *(u8**)&c64;
    if (sizeof(u8*) == (u16)4) p = *(u8**)&c32;
#endif
    Stdio.printf("ptr %u\n", condPtr(p));
    Stdio.printf("null %u\n", condPtr((u8*)0));

    Stdio.printf("u16 256 %u\n", condU16((u16)256));
    Stdio.printf("float half %u\n", condFloat((float)0.5));
    Stdio.printf("float zero %u\n", condFloat((float)0));
    float fz = (float)0;
    Stdio.printf("float -0 %u\n", condFloat(-fz));
    Stdio.printf("double half %u\n", condDouble((double)0.5));
    double dz = (double)0;
    Stdio.printf("double -0 %u\n", condDouble(-dz));

    Stdio.printf("pick %u %u\n", pickI64(hi, (u16)3, (u16)4),
                 pickI64((i64)0, (u16)3, (u16)4));
    Stdio.printf("pick %u %u\n", (u16)pickU32(top), (u16)pickU32((u64)0));
}
