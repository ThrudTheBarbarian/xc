// f8_decode_table.xc — every pattern of every 8-bit pack, and of f4, widened
// to f32 by the compiler's own conversion (a table load where the target has
// one) and by an explicit call of the library routine whose widths are read
// from volatile globals, so the call stays a call; the two are compared bit
// for bit, NaN payloads included. The packs: f8 (E4M3, finite), e5m2 (ieee),
// ue8m0, e3m4 (ieee), e5m2 finite, e2m5 none, e6m1 (ieee), and f4 (e2m1,
// none). Each line gives the pack, the number of patterns that differ and a
// checksum of the bits.
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "FloatPack.xc"
#import "FloatPackKinds.xc"

volatile u32 gE = 0;
volatile u32 gM = 0;
volatile u32 gK = 0;

u32 tab[256];

// A checksum step that keeps the high bits of a value in the low ones.
u32 mix(u32 x)
{
    return x ^ (x >> 13);
}

// The library routine on pattern h of the pack (gE, gM, gK).
u32 viaCall(u32 h)
{
    return _xt_fpk_bits(_xt_fpk_unpackk((u16)h, gE, gM, gK));
}

void report(string name, u32 n, u32 e, u32 m, u32 k)
{
    gE = e;
    gM = m;
    gK = k;
    u32 bad = 0;
    u32 sum = 0;
    for (u32 h = 0; h < n; h++)
    {
        u32 c = viaCall(h);
        if (c != tab[h])
        {
            if (bad == 0)
                Stdio.printf("  %x: %x:%x %x:%x\n", (u16)h, (u16)(tab[h] >> 16), (u16)tab[h],
                             (u16)(c >> 16), (u16)c);
            bad++;
        }
        sum = sum * 31 + mix(tab[h]);
    }
    Stdio.printf("%s %u %x:%x\n", name, (u16)bad, (u16)(sum >> 16), (u16)sum);
}

void e4m3(f8* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e5m2(f8:pack(e5m2)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void ue8m0(f8:pack(ue8m0)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e3m4(f8:pack(e3m4)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e5m2f(f8:pack(e5m2, finite)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e2m5n(f8:pack(e2m5, none)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e6m1(f8:pack(e6m1)* a)
{
    for (u32 i = 0; i < 256; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

void e2m1(f4[] a)
{
    for (u32 i = 0; i < 16; i++)
        tab[i] = _xt_fpk_bits(a[i]);
}

// One value at a time through a scalar of each pack, and to f64 and back.
f32 one(f8 x) { return x; }
f64 wide(f8:pack(e5m2) x) { return x; }
f32 nib(f4 x) { return x; }

i32 main()
{
    u8* raw = new u8[256];
    for (u32 i = 0; i < 256; i++)
        raw[i] = (u8)i;
    e4m3((f8*)raw);
    report("e4m3", 256, 4, 3, 1);
    e5m2((f8:pack(e5m2)*)raw);
    report("e5m2", 256, 5, 2, 0);
    ue8m0((f8:pack(ue8m0)*)raw);
    report("ue8m0", 256, 8, 0, 4);
    e3m4((f8:pack(e3m4)*)raw);
    report("e3m4", 256, 3, 4, 0);
    e5m2f((f8:pack(e5m2, finite)*)raw);
    report("e5m2,finite", 256, 5, 2, 1);
    e2m5n((f8:pack(e2m5, none)*)raw);
    report("e2m5,none", 256, 2, 5, 2);
    e6m1((f8:pack(e6m1)*)raw);
    report("e6m1", 256, 6, 1, 0);
    u8* nibs = new u8[8];
    for (u32 i = 0; i < 8; i++)
        nibs[i] = (u8)((2 * i) | ((2 * i + 1) << 4));
    e2m1((f4[])nibs);
    report("e2m1", 16, 2, 1, 2);

    // The scalar paths: every pattern through a function of each pack.
    u32 sum = 0;
    gE = 4;
    gM = 3;
    gK = 1;
    u32 bad = 0;
    for (u32 h = 0; h < 256; h++)
    {
        u8 b = (u8)h;
        u32 x = _xt_fpk_bits(one(*(f8*)&b));
        if (x != viaCall(h))
            bad++;
        sum = sum * 31 + mix(x);
        f64 d = wide(*(f8:pack(e5m2)*)&b);
        f32 back = (f32)d;
        sum = sum * 31 + mix(_xt_fpk_bits(back));
    }
    gE = 2;
    gM = 1;
    gK = 2;
    for (u32 h = 0; h < 16; h++)
    {
        u8 b = (u8)h;
        f4[] p = (f4[])&b;
        u32 x = _xt_fpk_bits(nib(p[0]));
        if (x != viaCall(h))
            bad++;
        sum = sum * 31 + mix(x);
    }
    Stdio.printf("scalar %u %x:%x\n", (u16)bad, (u16)(sum >> 16), (u16)sum);
    return 0;
}
