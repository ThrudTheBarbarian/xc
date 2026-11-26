// f16_nan_pairs.xc — + - * / on pairs of two NaNs, quiet and signalling, in
// f16 and bf16, folded into checksums. On arm64 an operation on two NaNs
// returns the first signalling one (made quiet), else the first, so which
// payload comes back depends on which operands are signalling. A target that
// widens a half in its own instructions makes a signalling NaN quiet where
// the FloatPack routines keep it signalling; the checksums (made with the
// routines) show that the native path gives the routines' payload. Other
// targets pick between two NaNs by other rules, so this runs on arm64 only.
//xtc-flags: target=arm64
//xtc-na: x86_64, win64, arm9, m68k, xt6502, wasm32 — which of two NaNs an operation returns differs by target; this pins arm64's
#import "Stdio.xc"

u32 mix(u32 h, u32 x)
{
    return (h ^ x) * 16777619;
}

u32 hb(f16 h) { return *(u16*)&h; }
u32 gb(bf16 g) { return *(u16*)&g; }
u32 fb(f32 f) { return *(u32*)&f; }

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

// A NaN of either kind: the exponent all ones, a nonzero mantissa.
f16 nanh(void)
{
    u32 r = next();
    u32 m = r & 1023;
    if (m == 0)
        m = 1;
    u16 x = (u16)((r & 32768) | 31744 | m);
    return *(f16*)&x;
}

bf16 nang(void)
{
    u32 r = next();
    u32 m = r & 127;
    if (m == 0)
        m = 1;
    u16 x = (u16)((r & 32768) | 32640 | m);
    return *(bf16*)&x;
}

i32 main()
{
    u32 s = 2166136261;
    u32 d = 2166136261;
    u32 p = 2166136261;
    u32 q = 2166136261;
    u32 m = 2166136261;
    _seed = 362436069;
    for (u32 i = 0; i < 65536; i++)
        {
        f16 x = nanh();
        f16 y = nanh();
        s = mix(s, hb(x + y));
        d = mix(d, hb(x - y));
        p = mix(p, hb(x * y));
        q = mix(q, hb(x / y));
        m = mix(m, fb((f32)x * 0.75 + (f32)y));
        }
    Stdio.printf("f16 add %x sub %x mul %x div %x mixed %x\n", s, d, p, q, m);
    s = 2166136261;
    d = 2166136261;
    p = 2166136261;
    q = 2166136261;
    for (u32 i = 0; i < 65536; i++)
        {
        bf16 x = nang();
        bf16 y = nang();
        s = mix(s, gb(x + y));
        d = mix(d, gb(x - y));
        p = mix(p, gb(x * y));
        q = mix(q, gb(x / y));
        }
    Stdio.printf("bf16 add %x sub %x mul %x div %x\n", s, d, p, q);
    return 0;
}
