// `new T[n]` of a struct reserves sizeof(T) for each element: arrays of
// structs of 16, 12 and 8 bytes, allocated one after another, are filled
// and read back with no array overwriting its neighbour. On arm9 each
// element got 8 bytes whatever the struct, so the next allocation
// overlapped the tail (#722).
#import "Stdio.xc"

#define N 4096

struct Body { float x; float v; u16 kind; u8 tag; i32 n; }
struct W { u32 a; u32 b; u32 c; }
struct Pt { float x; float y; }

i32 main(void)
{
    Body* b = new Body[N];
    W* w = new W[N];
    Pt* p = new Pt[N];
    for (u32 i in 0..N)
    {
        b[i].x = (float)i;
        b[i].v = 0.5f;
        b[i].kind = (u16)(i % (u32)7);
        b[i].tag = (u8)(i & (u32)255);
        b[i].n = (i32)i - 1000;
        w[i].a = i;
        w[i].b = i * (u32)3;
        w[i].c = (u32)7;
        p[i].x = (float)(i % (u32)50);
        p[i].y = 2.0f;
    }
    u32 bad = (u32)0;
    for (u32 i in 0..N)
    {
        if (b[i].x != (float)i || b[i].v != 0.5f || b[i].kind != (u16)(i % (u32)7)
            || b[i].tag != (u8)(i & (u32)255) || b[i].n != (i32)i - 1000)
            bad = bad + (u32)1;
        if (w[i].a != i || w[i].b != i * (u32)3 || w[i].c != (u32)7)
            bad = bad + (u32)1;
        if (p[i].x != (float)(i % (u32)50) || p[i].y != 2.0f)
            bad = bad + (u32)1;
    }
    Stdio.printf("bad %u\n", bad);
    return 0;
}
