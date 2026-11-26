// f16_exhaustive.xc — every f16 and bf16 pattern widened to f32 and f64 and
// rounded back, and + - * / and < over a large pseudo-random sample of pairs,
// each folded into a checksum. Where a target converts and computes halves in
// its own instructions, the checksums must be the ones the FloatPack routines
// give (they were made with them): the same bits for every pattern, signalling
// NaNs, -0 and subnormals included. Integer conversions and the rounding of
// pseudo-random f32 and f64 patterns are folded in too. Pairs of two NaNs are
// left out of the arithmetic: which payload an operation on two NaNs returns
// differs between targets (f16_nan_pairs.xc has them on arm64).
//xtc-na: xt6502, m68k — a million software conversions take too long there
#import "Stdio.xc"

u32 mix(u32 h, u32 x)
{
    return (h ^ x) * 16777619;
}

u32 hb(f16 h) { return *(u16*)&h; }
u32 gb(bf16 g) { return *(u16*)&g; }
u32 fb(f32 f) { return *(u32*)&f; }

f16 hof(u32 b)
{
    u16 x = (u16)b;
    return *(f16*)&x;
}

bf16 gof(u32 b)
{
    u16 x = (u16)b;
    return *(bf16*)&x;
}

f32 fof(u32 b)
{
    return *(f32*)&b;
}

f64 dof(u32 hi, u32 lo)
{
    u64 x = ((u64)hi << 32) | (u64)lo;
    return *(f64*)&x;
}

u32 dlo(f64 d)
{
    u64 x = *(u64*)&d;
    return (u32)x;
}

u32 dhi(f64 d)
{
    u64 x = *(u64*)&d;
    return (u32)(x >> 32);
}

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

// Every half to f32, f64 and back; to integers.
void halves(void)
{
    u32 w = 2166136261;
    u32 d = 2166136261;
    u32 r = 2166136261;
    u32 n = 2166136261;
    for (u32 i = 0; i < 65536; i++)
        {
        f16 h = hof(i);
        f32 f = (f32)h;
        w = mix(w, fb(f));
        f64 e = (f64)h;
        d = mix(mix(d, dhi(e)), dlo(e));
        r = mix(r, hb((f16)f));
        n = mix(mix(mix(n, (u32)(i32)h), (u32)(u16)h), (u32)(i64)h);
        }
    Stdio.printf("f16 widen %x f64 %x round trip %x int %x\n", w, d, r, n);
}

void bhalves(void)
{
    u32 w = 2166136261;
    u32 d = 2166136261;
    u32 r = 2166136261;
    for (u32 i = 0; i < 65536; i++)
        {
        bf16 g = gof(i);
        f32 f = (f32)g;
        w = mix(w, fb(f));
        f64 e = (f64)g;
        d = mix(mix(d, dhi(e)), dlo(e));
        r = mix(r, gb((bf16)f));
        }
    Stdio.printf("bf16 widen %x f64 %x round trip %x\n", w, d, r);
}

// Pseudo-random f32 and f64 patterns rounded to each type, and integers.
void rounding(void)
{
    u32 a = 2166136261;
    u32 b = 2166136261;
    u32 c = 2166136261;
    u32 k = 2166136261;
    _seed = 2463534242;
    for (u32 i = 0; i < 262144; i++)
        {
        u32 x = next();
        f32 f = fof(x);
        a = mix(a, hb((f16)f));
        b = mix(b, gb((bf16)f));
        // Doubles near f16's range, so most round to a finite half.
        u32 hi = (x & 2148532223) | ((1008 + (next() % 40)) << 20);
        c = mix(c, hb((f16)dof(hi, next())));
        i32 v = (i32)next() >> (x & 31);
        k = mix(mix(k, hb((f16)v)), hb((f16)(u32)v));
        }
    Stdio.printf("to f16 %x to bf16 %x f64 to f16 %x ints %x\n", a, b, c, k);
}

void arith(void)
{
    u32 s = 2166136261;
    u32 d = 2166136261;
    u32 p = 2166136261;
    u32 q = 2166136261;
    u32 lt = 0;
    u32 m = 2166136261;
    _seed = 88675123;
    for (u32 i = 0; i < 131072; i++)
        {
        f16 x = hof(next());
        f16 y = hof(next());
        if ((hb(x) & 32767) > 31744 && (hb(y) & 32767) > 31744)
            y = 1.0;
        s = mix(s, hb(x + y));
        d = mix(d, hb(x - y));
        p = mix(p, hb(x * y));
        q = mix(q, hb(x / y));
        if (x < y)
            lt = lt + 1;
        m = mix(m, fb((f32)x * 0.75 + (f32)y));
        }
    Stdio.printf("f16 add %x sub %x mul %x div %x lt %d mixed %x\n", s, d, p, q, lt, m);
}

void barith(void)
{
    u32 s = 2166136261;
    u32 d = 2166136261;
    u32 p = 2166136261;
    u32 q = 2166136261;
    u32 lt = 0;
    _seed = 521288629;
    for (u32 i = 0; i < 131072; i++)
        {
        bf16 x = gof(next());
        bf16 y = gof(next());
        if ((gb(x) & 32767) > 32640 && (gb(y) & 32767) > 32640)
            y = 1.0;
        s = mix(s, gb(x + y));
        d = mix(d, gb(x - y));
        p = mix(p, gb(x * y));
        q = mix(q, gb(x / y));
        if (x < y)
            lt = lt + 1;
        }
    Stdio.printf("bf16 add %x sub %x mul %x div %x lt %d\n", s, d, p, q, lt);
}

i32 main()
{
    halves();
    bhalves();
    rounding();
    arith();
    barith();
    return 0;
}
