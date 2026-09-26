// int_to_ptr_full_width.xc — bug 360. Converting an integer to a pointer
// keeps the full width of the target's pointer. arm64 masked the result to 16
// bits, so a real address stored in an i64 and cast back faulted.
//
// A global, a heap object and a stack local each go through i64, u64 and
// (where a pointer is 4 bytes or less) u32 and back, and are dereferenced.
// The Map/Set sentinels (pointer)0 and (pointer)1 and small-integer round
// trips keep working. A signed integer narrower than the pointer is
// sign-extended; on xt6502 that fills the 16-bit address and the bank is 0.

#import "Stdio.xc"

class Box
{
    u32 v;
}

u32 gw[4];

u32 viaI64(u32* p)
{
    i64 c = (i64)(pointer)p;
    u32* q = (u32*)(pointer)c;
    return q[0];
}

u32 viaU64(u32* p)
{
    u64 c = (u64)(pointer)p;
    u32* q = (u32*)(pointer)c;
    return q[0];
}

// u32 holds an address only where a pointer is 4 bytes or less; elsewhere the
// check reports the value it would have read.
u32 viaU32(u32* p)
{
    if (sizeof(pointer) > (u32)4)
        return p[0];
    u32 c = (u32)(pointer)p;
    u32* q = (u32*)(pointer)c;
    return q[0];
}

bool sameI64(u32* p)
{
    i64 c = (i64)(pointer)p;
    return (u32*)(pointer)c == p;
}

void check(u32* p, u32 want)
{
    Stdio.printf("%ld %ld %ld %ld\n",
                 (i32)(viaI64(p) == want), (i32)(viaU64(p) == want),
                 (i32)(viaU32(p) == want), (i32)sameI64(p));
}

void main(void)
{
    gw[1] = (u32)77;
    Stdio.printf("global ");
    check(&gw[1], (u32)77);

    // The literal case from the bug report.
    i64 c = (i64)(pointer)(&gw[1]);
    u32* q = (u32*)(pointer)c;
    Stdio.printf("q %ld\n", (i32)q[0]);

    Box* b = new Box();
    b.v = (u32)88;
    Stdio.printf("heap ");
    check(&b.v, (u32)88);
    i64 bi = (i64)(pointer)b;
    Box* b2 = (Box*)(pointer)bi;
    Stdio.printf("heap object %ld\n", (i32)b2.v);

    u32 loc = (u32)99;
    Stdio.printf("stack ");
    check(&loc, (u32)99);

    // Sentinels and small integers.
    pointer z = (pointer)0;
    pointer one = (pointer)1;
    Stdio.printf("null %ld\n", (i32)(z == (pointer)0));
    Stdio.printf("one %ld %ld\n", (i32)(one != z), (i32)(one == (pointer)1));
    Stdio.printf("u16 %ld\n", (i32)(u16)(pointer)(u16)1234);
    u32 big = (u32)$12345;
    Stdio.printf("u32 %ld\n", (i32)((u32)(pointer)big == big));
    i32 zero = (i32)0;
    i32 onei = (i32)1;
    Stdio.printf("from i32 %ld %ld\n", (i32)((pointer)zero == z), (i32)((pointer)onei == one));

    // A signed source is sign-extended: -1 from any signed width is the same
    // pointer (xt6502: the same 16-bit address, bank 0).
    i16 m16 = (i16)-1;
    i32 m32 = (i32)-1;
    i64 m64 = (i64)-1;
    pointer p16 = (pointer)m16;
    pointer p32 = (pointer)m32;
    pointer p64 = (pointer)m64;
    bool banked = sizeof(pointer) == (u32)3;
    Stdio.printf("signed %ld %ld\n", (i32)(banked || p16 == p32), (i32)(banked || p32 == p64));
    i8 m8 = (i8)-1;
    Stdio.printf("signed i8 %ld\n", (i32)((pointer)m8 == p16));
    Stdio.printf("signed u16 %ld\n", (i32)(u16)(pointer)m16);
    Stdio.printf("bank %ld\n", (i32)(!banked || (u32)(pointer)m16 == (u32)$FFFF));
    Stdio.printf("unsigned %ld %ld\n", (i32)((pointer)(u16)$FFFF == (pointer)(u32)$FFFF),
                 (i32)(banked || (pointer)(u16)$FFFF != p16));
    // An unsigned source with its top bit set is zero-extended.
    u32 hu = (u32)$FFFFFFF0;
    Stdio.printf("high u32 %ld %ld\n", (i32)(banked || (u64)(pointer)hu == (u64)hu),
                 (i32)(banked || (u64)(pointer)(u32)$FFFFFFF0 == (u64)$FFFFFFF0));
}
