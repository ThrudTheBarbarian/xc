// not_pointer_aligned.xc — bug 291. `!p` on a pointer is true only for null.
// One compiler narrowed the pointer to 16 bits before comparing it with zero,
// so on a 32- or 64-bit target a pointer to a 64 KB boundary read as null.
// On xt6502 a pointer is null by its two address bytes, so there the test is
// a pointer whose low byte is zero, as for a condition (bug 272).

#import "Stdio.xc"

#if ARCH_6502
u8 gBuf[512];
u32 gAlign = (u32)256;
#else
u8 gBuf[140000];
u32 gAlign = (u32)65536;
#endif

u16 test(u8* p)
{
    u16 r = (u16)0;
    if (p) r = r + (u16)1;
    if (!p) r = r + (u16)10;
    bool b = !p;
    if (b) r = r + (u16)100;
    return r;
}

void main(void)
{
    u8* p = &gBuf[0];
    u32 low = (u32)((u64)(pointer)p % (u64)gAlign);
    u32 off = (gAlign - low) % gAlign;
    u8* z = &gBuf[off];
    Stdio.printf("aligned %u\n", (u16)((u64)(pointer)z % (u64)gAlign == (u64)0));
    Stdio.printf("pointer %u\n", test(z));
    Stdio.printf("null %u\n", test((u8*)0));
}
