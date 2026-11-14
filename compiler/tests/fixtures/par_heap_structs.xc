// par_heap_structs.xc — `par` blocks over HEAP arrays of structs (#113). A
// `new P[n]` of 64 KB or more is page-aligned and registered by its allocator,
// as a numeric array is, so a block sizes it at run time and runs on the GPU
// with the struct held as words (#37): mixed widths and padding here. A small
// one (under 64 KB) is in no registered block and stays on the CPU. Every sum
// is the same on the CPU and on every GPU (tests/par/heap-structs.sh).
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 262144
#define S 1024

struct Body { float x; float v; u16 kind; u8 tag; i32 n; }
struct Pt { float x; float y; }

i32 main(void)
{
    Body* b = new Body[N];
    Pt* p = new Pt[N];
    Pt* small = new Pt[S];
    for (u32 i in 0..N)
    {
        b[i].x = (float)(i % (u32)100);
        b[i].v = 0.25f;
        b[i].kind = (u16)(i % (u32)7);
        b[i].tag = (u8)(i & (u32)255);
        b[i].n = (i32)i - 100000;
        p[i].x = (float)(i % (u32)50);
        p[i].y = 2.0f;
    }
    for (u32 i in 0..S)
    {
        small[i].x = (float)i;
        small[i].y = 1.0f;
    }
    par bodies
    {
        for (u32 i in 0..N)
        {
            b[i].x = b[i].x + b[i].v * 4.0f;
            b[i].kind = b[i].kind ^ (u16)0x101;
            b[i].tag = b[i].tag + (u8)3;
            b[i].n = b[i].n * 3;
        }
    }
    par points
    {
        for (u32 i in 0..N)
            p[i].x = p[i].x * p[i].y + 1.0f;
    }
    par few
    {
        for (u32 i in 0..S)
            small[i].x = small[i].x + small[i].y;
    }
    float sx = 0.0f; u32 sk = (u32)0; u32 st = (u32)0; i64 sn = (i64)0;
    for (u32 i in 0..N)
    {
        sx = sx + b[i].x;
        sk = sk + (u32)b[i].kind;
        st = st + (u32)b[i].tag;
        sn = sn + (i64)b[i].n;
    }
    float px = 0.0f;
    for (u32 i in 0..N) px = px + p[i].x;
    float qx = 0.0f;
    for (u32 i in 0..S) qx = qx + small[i].x;
    Stdio.printf("bodies %f %u %u %lld\n", sx, sk, st, sn);
    Stdio.printf("points %f\n", px);
    Stdio.printf("few %f\n", qx);
    return 0;
}
