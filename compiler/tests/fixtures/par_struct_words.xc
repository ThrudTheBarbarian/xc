// par_struct_words.xc — `par` blocks over arrays of structs whose fields are
// not all 4 bytes. A kernel holds such an array as words (32-bit here, 16-bit
// for Small, whose widest field is a u16) in the host's layout: padding, a
// nested struct, a bool and fields of 1, 2, 4 and 8 bytes. Each block works
// on a global array of structs, or on a local one it captures, and the sums
// are the same on the CPU and on every GPU (tests/par/structs.sh runs both).
// parspv-diff holds the two compilers' kernels to the same bytes.
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 65536
#define L 8192

struct Tag { u8 kind; i16 dz; }
struct Mixed { u8 a; i8 b; u16 c; i32 d; float e; i64 f; double g; bool h; Tag t; }
struct Small { u8 r; i8 s; u16 w; }
struct Vec3 { float x; float y; float z; }
struct Rec { u8 k; i32 v; u16 w; }

Mixed ms[N];
Small sm[N];
Vec3 pos[N];

i32 main(void)
{
    Rec loc[L];
    for (u32 i in 0..N)
    {
        ms[i].a = (u8)(i & (u32)255);
        ms[i].b = (i8)((i32)(i % (u32)200) - 100);
        ms[i].c = (u16)(i * (u32)7);
        ms[i].d = (i32)i - 30000;
        ms[i].e = (float)(i % (u32)64) * 0.5f;
        ms[i].f = (i64)i * (i64)100000;
        ms[i].h = (i % (u32)3) == (u32)0;
        ms[i].t.kind = (u8)(i % (u32)7);
        ms[i].t.dz = (i16)(i % (u32)1000) - (i16)500;
        sm[i].r = (u8)i;
        sm[i].s = (i8)(i % (u32)100);
        sm[i].w = (u16)i;
        pos[i].x = (float)(i % (u32)100);
        pos[i].y = 1.0f;
        pos[i].z = 0.5f;
    }
    for (u32 i in 0..L)
    {
        loc[i].k = (u8)(i % (u32)250);
        loc[i].v = (i32)i;
        loc[i].w = (u16)(i * (u32)3);
    }
    par mixed
    {
        for (u32 i in 0..N)
        {
            ms[i].a = ms[i].a + (u8)1;
            ms[i].b = ms[i].b - (i8)3;
            ms[i].c = ms[i].c ^ (u16)0x5555;
            ms[i].d = ms[i].d * 3;
            ms[i].e = ms[i].e + (float)ms[i].b;
            ms[i].h = !ms[i].h;
            ms[i].t.kind = ms[i].t.kind + ms[i].a;
            ms[i].t.dz = ms[i].t.dz * (i16)2;
        }
    }
    par wide
    {
        for (u32 i in 0..N)
            ms[i].f = ms[i].f + (i64)ms[i].d;
    }
    par small
    {
        for (u32 i in 0..N)
        {
            sm[i].r = sm[i].r * (u8)3;
            sm[i].s = (i8)0 - sm[i].s;
            sm[i].w = sm[i].w + (u16)sm[i].r;
        }
    }
    par vec
    {
        for (u32 i in 0..N)
        {
            pos[i].x = pos[i].x + pos[i].y;
            pos[i].z = pos[i].z * 2.0f;
        }
    }
    par local
    {
        for (u32 i in 0..L)
        {
            loc[i].v = loc[i].v + (i32)loc[i].k * 2;
            loc[i].w = loc[i].w + (u16)1;
            loc[i].k = (u8)(loc[i].v & 127);
        }
    }
    i64 s = (i64)0;
    float fs = 0.0f;
    for (u32 i in 0..N)
    {
        s = s + (i64)ms[i].a + (i64)ms[i].b * (i64)3 + (i64)ms[i].c + (i64)ms[i].d + (i64)(ms[i].e * 4.0f)
          + ms[i].f % (i64)1000003 + (ms[i].h ? (i64)5 : (i64)0) + (i64)ms[i].t.kind + (i64)ms[i].t.dz;
        s = s + (i64)sm[i].r + (i64)sm[i].s * (i64)7 + (i64)sm[i].w;
        fs = fs + pos[i].x + pos[i].z;
    }
    for (u32 i in 0..L)
        s = s + (i64)loc[i].k * (i64)1000 + (i64)loc[i].v + (i64)loc[i].w;
    Stdio.printf("%ld %.1f %u %u\n", s, (double)fs, (u32)sizeof(Mixed), (u32)sizeof(Small));
    return 0;
}
