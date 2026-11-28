// f8_narrow_inline.xc — f32 to each signed 8-bit pack and to f4 by the
// compiler's own conversion (a branch-free sequence where the target has one)
// and by an explicit call of the library routine whose widths are read from
// volatile globals, so the call stays a call; the two are compared bit for
// bit. The values: the specials (zeros, infinities, NaNs with payloads, the
// largest and smallest f32s), pseudo-random bit patterns of every kind,
// patterns with exponents near the packs' ranges, and the same with the low
// mantissa bits cleared, which makes ties. Each line gives the pack, the
// number of values that differ and a checksum of the first 1024 patterns (the
// whole sample on the 8- and 16-bit targets, which take a smaller one).
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "FloatPack.xc"
#import "FloatPackKinds.xc"

#if ARCH_6502 || ARCH_m68k
#define COUNT 1024
#else
#define COUNT 65536
#endif

volatile u32 gE = 0;
volatile u32 gM = 0;
volatile u32 gK = 0;

u32 SPECIAL[24] = {$00000000, $80000000, $7F800000, $FF800000, $7FC00000, $FFC00000, $7F800001, $FF800001, $7FA00000, $7FBFFFFF, $7FFFFFFF, $FFFFFFFF, $7F7FFFFF, $FF7FFFFF, $00000001, $80000001, $007FFFFF, $00800000, $43E00000, $43E80000, $47600000, $47700000, $40C00000, $40E00000};

f32 vals[COUNT];
u8 got[COUNT];

f32 ffrom(u32 u) { return *(f32*)&u; }

void fill(void)
{
    for (u32 i = 0; i < 24; i++)
        vals[i] = ffrom(SPECIAL[i]);
    u32 x = 2463534242;
    for (u32 i = 24; i < COUNT; i++)
    {
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        u32 b = x;
        u32 kind = i % 3;
        if (kind != 0)
            b = (b & $807FFFFF) | ((100 + (b >> 8) % 50) << 23);
        if (kind == 2)
            b = b & $FFFF0000;
        vals[i] = ffrom(b);
    }
}

// The library routine on value i, to the pack (gE, gM, gK): FloatPack's for
// an ieee pack, FloatPackKinds' for the others.
u32 viaCall(u32 i)
{
    if (gK == 0)
        return (u32)_xt_fpk_pack_f32(vals[i], gE, gM);
    return (u32)_xt_fpk_pack_f32k(vals[i], gE, gM, gK);
}

void report(string name, u32 e, u32 m, u32 k)
{
    gE = e;
    gM = m;
    gK = k;
    u32 bad = 0;
    u32 sum = 0;
    for (u32 i = 0; i < COUNT; i++)
    {
        u32 c = viaCall(i);
        if (c != (u32)got[i])
        {
            if (bad < 3)
            {
                u32 b = *(u32*)&vals[i];
                Stdio.printf("  %x:%x %x %x\n", (u16)(b >> 16), (u16)b, (u16)got[i], (u16)c);
            }
            bad++;
        }
        if (i < 1024)
            sum = sum * 31 + (u32)got[i];
    }
    Stdio.printf("%s %u %x:%x\n", name, (u16)bad, (u16)(sum >> 16), (u16)sum);
}

void e4m3(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8 v = (f8)vals[i];
        got[i] = *(u8*)&v;
    }
}

void e5m2(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8:pack(e5m2) v = (f8:pack(e5m2))vals[i];
        got[i] = *(u8*)&v;
    }
}

void e3m4(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8:pack(e3m4) v = (f8:pack(e3m4))vals[i];
        got[i] = *(u8*)&v;
    }
}

void e5m2f(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8:pack(e5m2, finite) v = (f8:pack(e5m2, finite))vals[i];
        got[i] = *(u8*)&v;
    }
}

void e2m5n(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8:pack(e2m5, none) v = (f8:pack(e2m5, none))vals[i];
        got[i] = *(u8*)&v;
    }
}

void e6m1(void)
{
    for (u32 i = 0; i < COUNT; i++)
    {
        f8:pack(e6m1) v = (f8:pack(e6m1))vals[i];
        got[i] = *(u8*)&v;
    }
}

void e2m1(f4[] a)
{
    for (u32 i = 0; i < COUNT; i++)
        a[i] = (f4)vals[i];
    for (u32 i = 0; i < COUNT; i++)
    {
        f4 v = a[i];
        got[i] = *(u8*)&v;
    }
}

i32 main()
{
    fill();
    e4m3();
    report("e4m3", 4, 3, 1);
    e5m2();
    report("e5m2", 5, 2, 0);
    e3m4();
    report("e3m4", 3, 4, 0);
    e5m2f();
    report("e5m2,finite", 5, 2, 1);
    e2m5n();
    report("e2m5,none", 2, 5, 2);
    e6m1();
    report("e6m1", 6, 1, 0);
    f4[] nibs = (f4[])new u8[COUNT / 2];
    e2m1(nibs);
    report("e2m1", 2, 1, 2);
    return 0;
}
