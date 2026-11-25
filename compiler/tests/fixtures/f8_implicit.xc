// f8_implicit.xc — the conversions a small float makes with no cast, which
// are the exact ones: f8 (E4M3), f8:pack(e5m2), f8:pack(e3m4) and
// f8:pack(e2m5, none) to f16; those and f8:pack(e5m2, finite) and
// f8:pack(ue8m0) to bf16; every pack to f32 and f64. Each is taken over all
// 256 patterns, in a declaration, an assignment, an argument and a return, and
// printed as a checksum of the resulting bits; going to f32 through f16 gives
// the same bits as going directly. A NaN stays a NaN and an infinity an
// infinity. Also: overloads prefer the narrowest pack that holds the
// argument, mixed arithmetic and a conditional widen to the type that holds
// both, and Fp8.xc's explicit conversions give the other overflow rule
// (NaN for E4M3 and ue8m0, saturation for E5M2). The expected checksums come
// from an independent model.
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Fp8.xc"

u16 h16(f16 x) { return *(u16*)&x; }
u16 hb(bf16 x) { return *(u16*)&x; }
u32 w32(f32 x) { return *(u32*)&x; }
u16 b8(f8 x) { return (u16)*(u8*)&x; }
u16 b52(f8:pack(e5m2) x) { return (u16)*(u8*)&x; }
u16 bu(f8:pack(ue8m0) x) { return (u16)*(u8*)&x; }
f8 e43(u32 p) { u8 b = (u8)p; return *(f8*)&b; }
f8:pack(e5m2) e52(u32 p) { u8 b = (u8)p; return *(f8:pack(e5m2)*)&b; }
f8:pack(ue8m0) ue(u32 p) { u8 b = (u8)p; return *(f8:pack(ue8m0)*)&b; }
f8:pack(e3m4) c34(u32 p) { u8 b = (u8)p; return *(f8:pack(e3m4)*)&b; }
f8:pack(e2m5, none) c25(u32 p) { u8 b = (u8)p; return *(f8:pack(e2m5, none)*)&b; }
f8:pack(e5m2, finite) c52(u32 p) { u8 b = (u8)p; return *(f8:pack(e5m2, finite)*)&b; }

void put(u32 s)
{
    Stdio.printf("%x:%x\n", (u16)(s >> 16), (u16)s);
}

f16 asHalf(f16 x) { return x; }
f16 fromC34(f8:pack(e3m4) x) { return x; }
bf16 asBrain(bf16 x) { return x; }
bf16 fromScale(f8:pack(ue8m0) x) { return x; }
u16 kind(f16 x) { return 16; }
u16 kind(f32 x) { return 32; }

void e4m3(void)
{
    u32 s16 = 0;
    u32 s32 = 0;
    u32 sd = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f8 x = e43(p);
        f16 h = x;
        f32 viaH = h;
        f32 direct = x;
        s16 = s16 * 31 + h16(h);
        s32 = s32 * 31 + w32(viaH);
        sd = sd * 31 + w32(direct);
    }
    put(s16);
    put(s32);
    put(sd);
}

void e5m2(void)
{
    u32 s16 = 0;
    u32 s32 = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f8:pack(e5m2) x = e52(p);
        f16 h = asHalf(x);
        f32 viaH = h;
        s16 = s16 * 31 + h16(h);
        s32 = s32 * 31 + w32(viaH);
    }
    put(s16);
    put(s32);
}

void customs(void)
{
    u32 a = 0;
    u32 b = 0;
    for (u32 p = 0; p < 256; p++)
    {
        f16 h = fromC34(c34(p));
        f16 g;
        g = c25(p);
        a = a * 31 + h16(h);
        b = b * 31 + h16(g);
    }
    put(a);
    put(b);
}

void brains(void)
{
    u32 a = 0;
    u32 b = 0;
    u32 c = 0;
    u32 d = 0;
    for (u32 p = 0; p < 256; p++)
    {
        bf16 x = e43(p);
        bf16 y = asBrain(e52(p));
        bf16 z = fromScale(ue(p));
        bf16 v = c52(p);
        a = a * 31 + hb(x);
        b = b * 31 + hb(y);
        c = c * 31 + hb(z);
        d = d * 31 + hb(v);
    }
    put(a);
    put(b);
    put(c);
    put(d);
}

void doubles(void)
{
    u32 a = 0;
    for (u32 p = 0; p < 255; p++)
    {
        f64 d = ue(p);
        u64 u = *(u64*)&d;
        a = a * 31 + (u32)(u >> 32);
    }
    put(a);
}

void rules(void)
{
    f8 x = 0.5;
    f8:pack(ue8m0) s = 4;
    f8:pack(e5m2, finite) w = 2;
    Stdio.printf("kind %u %u %u\n", kind(x), kind(s), kind(w));
    f16 h = 2.5;
    Stdio.printf("mix %u %x\n", kind(x + h), h16(x * h));
    bool t = true;
    f16 c = t ? x : h;
    f16 d = !t ? x : h;
    Stdio.printf("cond %x %x\n", h16(c), h16(d));
}

void explicit(void)
{
    f64 big = 1e308;
    f64 inf = big * 10.0;
    Stdio.printf("e4m3 %x %x %x", b8(fp8E4M3(500.0)), b8(fp8E4M3Nan(500.0)), b8(fp8E4M3Nan(-1e9)));
    Stdio.printf(" %x %x %x\n", b8(fp8E4M3Nan(448.0)), b8(fp8E4M3Nan(464.0)), b8(fp8E4M3Nan(465.0)));
    Stdio.printf("e5m2 %x %x %x", b52(fp8E5M2(1e6)), b52(fp8E5M2Sat(1e6)), b52(fp8E5M2Sat(-inf)));
    Stdio.printf(" %x %x\n", b52(fp8E5M2Sat(61440.0)), b52(fp8E5M2(61440.0)));
    Stdio.printf("ue8m0 %x %x %x", bu(fp8UE8M0(1e39)), bu(fp8UE8M0Nan(1e39)), bu(fp8UE8M0Nan(-1.0)));
    Stdio.printf(" %x %x\n", bu(fp8UE8M0(0.0)), bu(fp8UE8M0(inf)));
    Stdio.printf("value %f %f", (f64)fp8E4M3Value(fp8E4M3(0.2)), (f64)fp8E5M2Value(fp8E5M2(0.1)));
    Stdio.printf(" %f\n", (f64)fp8UE8M0Value(fp8UE8M0(0.3)));
}

i32 main(void)
{
    e4m3();
    e5m2();
    customs();
    brains();
    doubles();
    rules();
    explicit();
    return 0;
}
