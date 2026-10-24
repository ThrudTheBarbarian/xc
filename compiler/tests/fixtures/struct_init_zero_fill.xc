// Omitted trailing members of a struct initialiser are zero-filled (types.md),
// as an array's omitted elements are: `P p = {1.0};` left p.b and p.c as
// whatever the stack held (Astronomancy's affine transforms). The stack is
// dirtied first so leftovers would show; every member is compared exactly.
#import "Stdio.xc"
struct Inner { u16 q; float r; }
struct P
    {
    double a;
    double b;
    float c;
    u8 d;
    i64 e;
    u32* f;
    Inner g;
    u16 h[3];
    }
void dirty(void)
    {
    u64 junk[64];
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
        junk[i] = (u64)0x4045123456789ABC;
    if (junk[7] == (u64)1)
        Stdio.printf("never\n");
    }
u32 unset(P* p)
    {
    u32 bad = (u32)0;
    if (p.b != 0.0) bad = bad + (u32)1;
    if (p.c != (float)0.0) bad = bad + (u32)1;
    if (p.d != (u8)0) bad = bad + (u32)1;
    if (p.e != (i64)0) bad = bad + (u32)1;
    if (p.f != (u32*)0) bad = bad + (u32)1;
    if (p.g.q != (u16)0 || p.g.r != (float)0.0) bad = bad + (u32)1;
    if (p.h[0] != (u16)0 || p.h[1] != (u16)0 || p.h[2] != (u16)0) bad = bad + (u32)1;
    return bad;
    }
u32 one(void)
    {
    P p = {1.5};
    return unset(&p) + (p.a == 1.5 ? (u32)0 : (u32)100);
    }
u32 two(void)
    {
    P p = {2.0, 3.0, (float)4.0, (u8)5};
    u32 bad = (u32)0;
    if (p.e != (i64)0 || p.f != (u32*)0 || p.g.q != (u16)0 || p.h[2] != (u16)0) bad = (u32)1;
    return bad + (p.b == 3.0 && p.d == (u8)5 ? (u32)0 : (u32)100);
    }
i32 main(void)
    {
    dirty();
    u32 a = one();
    dirty();
    u32 b = two();
    Stdio.printf("unset members left: %u and %u\n", a, b);
    return 0;
    }
