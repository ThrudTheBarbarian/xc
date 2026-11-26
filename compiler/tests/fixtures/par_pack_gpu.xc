// par_pack_gpu.xc — the small floats on the GPU against the CPU, bit for bit.
// Every f16 and bf16 pattern widened to f32 and rounded back; every f8 (E4M3
// and E5M2) pattern widened; pseudo-random f32 patterns rounded to each type;
// and + - * / and < over a million pseudo-random pairs of f16, of bf16 (half
// of them near and below the smallest normal, where a GPU that flushes
// subnormal floats would differ) and every pair of E4M3. Each block runs once
// with :device(cpu) and once with :device(gpu); the outputs are compared
// pattern by pattern. A pair whose result is a NaN on both devices counts as
// the same: which NaN an operation on a NaN returns is the device's own. On a
// target with no GPU both blocks run on the CPU, and the output is the same.
// The loops that fill and compare stay serial, so the CPU checks the GPU.
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define P 65536
#define R 262144
#define Q 1048576

f16 h[P];
bf16 g[P];
f8 e4[P];
f8:pack(e5m2) e5[P];
f32 wc[P];
f32 wg[P];
f16 hc[P];
f16 hg[P];

f32 src[R];
f16 rhc[R];
f16 rhg[R];
bf16 rbc[R];
bf16 rbg[R];
f8 rqc[R];
f8 rqg[R];

f16 x16[Q];
f16 y16[Q];
bf16 xb[Q];
bf16 yb[Q];
f16 oc16[Q];
f16 og16[Q];
bf16 ocb[Q];
bf16 ogb[Q];
u32 ltc[Q];
u32 ltg[Q];

u32 _seed;

u32 next(void)
{
    u32 x = _seed;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    _seed = x;
    return x;
}

bool nan16(u16 v, u32 e)
{
    return e == 5 ? (v & 32767) > 31744 : (v & 32767) > 32640;
}

// Patterns that differ, a NaN on both sides counting as the same.
u32 differ16(u16* a, u16* b, u32 n, u32 e)
{
    u32 bad = 0;
    for (u32 i in 0..n) : serial
        if (a[i] != b[i] && !(nan16(a[i], e) && nan16(b[i], e)))
            bad++;
    return bad;
}

u32 differ32(u32* a, u32* b, u32 n)
{
    u32 bad = 0;
    for (u32 i in 0..n) : serial
        if (a[i] != b[i] && !((a[i] & 2147483647) > 2139095040 && (b[i] & 2147483647) > 2139095040))
            bad++;
    return bad;
}

// E4M3 patterns: S.1111.111 is the one NaN of each sign.
u32 differ8(u8* a, u8* b, u32 n)
{
    u32 bad = 0;
    for (u32 i in 0..n) : serial
        if (a[i] != b[i] && !((a[i] & 127) == 127 && (b[i] & 127) == 127))
            bad++;
    return bad;
}

u32 sum16(u16* a, u32 n)
{
    u32 s = 2166136261;
    for (u32 i in 0..n) : serial
        if (!nan16(a[i], 5))
            s = (s ^ a[i]) * 16777619;
    return s;
}

void widen(void)
{
    u16* hb = (u16*)&h[0];
    u16* gb = (u16*)&g[0];
    u8* e4b = (u8*)&e4[0];
    u8* e5b = (u8*)&e5[0];
    for (u32 i in 0..P) : serial
    {
        hb[i] = (u16)i;
        gb[i] = (u16)i;
        e4b[i] = (u8)i;
        e5b[i] = (u8)(i >> 8);
    }
    u32* c = (u32*)&wc[0];
    u32* d = (u32*)&wg[0];
    par wideCpu :device(cpu) { for (u32 i in 0..P) { wc[i] = (f32)h[i]; hc[i] = (f16)wc[i]; } }
    par wideGpu :device(gpu) { for (u32 i in 0..P) { wg[i] = (f32)h[i]; hg[i] = (f16)wg[i]; } }
    Stdio.printf("f16 widen %d round trip %d\n", (i32)differ32(c, d, P),
                 (i32)differ16((u16*)&hc[0], (u16*)&hg[0], P, 5));
    par bwideCpu :device(cpu) { for (u32 i in 0..P) wc[i] = (f32)g[i]; }
    par bwideGpu :device(gpu) { for (u32 i in 0..P) wg[i] = (f32)g[i]; }
    Stdio.printf("bf16 widen %d\n", (i32)differ32(c, d, P));
    par f8Cpu :device(cpu) { for (u32 i in 0..P) wc[i] = (f32)e4[i] + (f32)e5[i]; }
    par f8Gpu :device(gpu) { for (u32 i in 0..P) wg[i] = (f32)e4[i] + (f32)e5[i]; }
    Stdio.printf("f8 widen %d\n", (i32)differ32(c, d, P));
}

void rounding(void)
{
    u32* s = (u32*)&src[0];
    _seed = 2463534242;
    for (u32 i in 0..R) : serial
    {
        // Every exponent, the mantissas pseudo-random, a quarter of them ties.
        u32 x = next();
        if ((i & 3) == 0)
            x = (x & 4294959104) | 4096;
        s[i] = x;
    }
    par roundCpu :device(cpu) { for (u32 i in 0..R) { f32 v = src[i]; rhc[i] = (f16)v; rbc[i] = (bf16)v; rqc[i] = (f8)v; } }
    par roundGpu :device(gpu) { for (u32 i in 0..R) { f32 v = src[i]; rhg[i] = (f16)v; rbg[i] = (bf16)v; rqg[i] = (f8)v; } }
    Stdio.printf("round f16 %d bf16 %d f8 %d\n", (i32)differ16((u16*)&rhc[0], (u16*)&rhg[0], R, 5),
                 (i32)differ16((u16*)&rbc[0], (u16*)&rbg[0], R, 8), (i32)differ8((u8*)&rqc[0], (u8*)&rqg[0], R));
}

void arith(void)
{
    u16* a = (u16*)&x16[0];
    u16* b = (u16*)&y16[0];
    u16* c = (u16*)&xb[0];
    u16* d = (u16*)&yb[0];
    _seed = 88675123;
    for (u32 i in 0..Q) : serial
    {
        a[i] = (u16)next();
        b[i] = (u16)next();
        u32 x = next();
        u32 y = next();
        // Half the bf16 pairs have exponents at or below the smallest
        // normal's, both signs.
        if ((i & 1) == 0)
        {
            x = x & 33023;
            y = y & 33023;
        }
        c[i] = (u16)x;
        d[i] = (u16)y;
    }
    for (u32 op = 0; op < 4; op++)
    {
        par opCpu :device(cpu)
        {
            for (u32 i in 0..Q)
            {
                f16 x = x16[i];
                f16 y = y16[i];
                bf16 p = xb[i];
                bf16 q = yb[i];
                f16 r = op == 0 ? x + y : op == 1 ? x - y : op == 2 ? x * y : x / y;
                bf16 t = op == 0 ? p + q : op == 1 ? p - q : op == 2 ? p * q : p / q;
                oc16[i] = r;
                ocb[i] = t;
                ltc[i] = (x < y ? 1 : 0) + (p < q ? 2 : 0) + (p == q ? 4 : 0);
            }
        }
        par opGpu :device(gpu)
        {
            for (u32 i in 0..Q)
            {
                f16 x = x16[i];
                f16 y = y16[i];
                bf16 p = xb[i];
                bf16 q = yb[i];
                f16 r = op == 0 ? x + y : op == 1 ? x - y : op == 2 ? x * y : x / y;
                bf16 t = op == 0 ? p + q : op == 1 ? p - q : op == 2 ? p * q : p / q;
                og16[i] = r;
                ogb[i] = t;
                ltg[i] = (x < y ? 1 : 0) + (p < q ? 2 : 0) + (p == q ? 4 : 0);
            }
        }
        Stdio.printf("op %d: f16 %d bf16 %d compare %d sum %x\n", (i32)op,
                     (i32)differ16((u16*)&oc16[0], (u16*)&og16[0], Q, 5),
                     (i32)differ16((u16*)&ocb[0], (u16*)&ogb[0], Q, 8),
                     (i32)differ32(&ltc[0], &ltg[0], Q), sum16((u16*)&oc16[0], Q));
    }
}

// Every pair of E4M3 patterns, multiplied and added.
void f8pairs(void)
{
    u8* a = (u8*)&e4[0];
    for (u32 i in 0..P) : serial
        a[i] = (u8)i;
    par f8opCpu :device(cpu) { for (u32 i in 0..P) { f8 x = e4[i]; f8 y = e4[i >> 8]; rqc[i] = x * y + x; } }
    par f8opGpu :device(gpu) { for (u32 i in 0..P) { f8 x = e4[i]; f8 y = e4[i >> 8]; rqg[i] = x * y + x; } }
    Stdio.printf("f8 ops %d\n", (i32)differ8((u8*)&rqc[0], (u8*)&rqg[0], P));
}

i32 main(void)
{
    widen();
    rounding();
    arith();
    f8pairs();
    return 0;
}
