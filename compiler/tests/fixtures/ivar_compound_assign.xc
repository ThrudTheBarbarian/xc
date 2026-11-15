//xtc-na: xt6502, m68k — prints 32- and 64-bit values through %ld
// A compound assignment to an ivar named bare inside a method (`n op= x`):
// every operator on u8, i16, u32, i64 and double ivars, on an inherited ivar
// in a subclass method, through a method called on a subclass instance, and
// with a parameter or a local of the same name, which takes the update and
// leaves the ivar alone. Shifts take u8, u32 and u64 counts on ivars, locals
// and globals.
#use Stdio

u8 g8;
i16 g16;
u32 g32;
i64 g64;

class Acc
{
    u8 a;
    i16 b;
    u32 c;
    i64 d;
    double e;

    void bytes(void)
    {
        a = 250;
        a += 10;    Stdio.printf("u8 += %ld\n", (i64)a);
        a -= 5;     Stdio.printf("u8 -= %ld\n", (i64)a);
        a *= 3;     Stdio.printf("u8 *= %ld\n", (i64)a);
        a /= 7;     Stdio.printf("u8 /= %ld\n", (i64)a);
        a %= 5;     Stdio.printf("u8 %%= %ld\n", (i64)a);
        a |= $F0;   Stdio.printf("u8 |= %ld\n", (i64)a);
        a &= $3C;   Stdio.printf("u8 &= %ld\n", (i64)a);
        a ^= $FF;   Stdio.printf("u8 ^= %ld\n", (i64)a);
        a <<= 2;    Stdio.printf("u8 <<= %ld\n", (i64)a);
        a >>= 3;    Stdio.printf("u8 >>= %ld\n", (i64)a);
    }

    void shorts(void)
    {
        b = 32000;
        b += 1000;  Stdio.printf("i16 += %ld\n", (i64)b);
        b -= 7;     Stdio.printf("i16 -= %ld\n", (i64)b);
        b *= 3;     Stdio.printf("i16 *= %ld\n", (i64)b);
        b /= 9;     Stdio.printf("i16 /= %ld\n", (i64)b);
        b %= 1000;  Stdio.printf("i16 %%= %ld\n", (i64)b);
        b |= 1;     Stdio.printf("i16 |= %ld\n", (i64)b);
        b &= -4;    Stdio.printf("i16 &= %ld\n", (i64)b);
        b ^= 85;    Stdio.printf("i16 ^= %ld\n", (i64)b);
        b <<= 4;    Stdio.printf("i16 <<= %ld\n", (i64)b);
        b >>= 2;    Stdio.printf("i16 >>= %ld\n", (i64)b);
    }

    void words(u32 k)
    {
        c = 4000000000;
        c += k;     Stdio.printf("u32 += %ld\n", (i64)c);
        c -= 17;    Stdio.printf("u32 -= %ld\n", (i64)c);
        c *= 3;     Stdio.printf("u32 *= %ld\n", (i64)c);
        c /= 5;     Stdio.printf("u32 /= %ld\n", (i64)c);
        c %= 100000; Stdio.printf("u32 %%= %ld\n", (i64)c);
        c |= $F00;  Stdio.printf("u32 |= %ld\n", (i64)c);
        c &= $FFF0; Stdio.printf("u32 &= %ld\n", (i64)c);
        c ^= $5A5A; Stdio.printf("u32 ^= %ld\n", (i64)c);
        c <<= 20;   Stdio.printf("u32 <<= %ld\n", (i64)c);
        c >>= 9;    Stdio.printf("u32 >>= %ld\n", (i64)c);
    }

    void longs(i64 k)
    {
        d = -1234567890123;
        d += k;         Stdio.printf("i64 += %ld\n", d);
        d -= 1000;      Stdio.printf("i64 -= %ld\n", d);
        d *= 7;         Stdio.printf("i64 *= %ld\n", d);
        d /= 4;         Stdio.printf("i64 /= %ld\n", d);
        d %= 1000000;   Stdio.printf("i64 %%= %ld\n", d);
        d <<= 33;       Stdio.printf("i64 <<= %ld\n", d);
        d >>= 30;       Stdio.printf("i64 >>= %ld\n", d);
        d |= 1;         Stdio.printf("i64 |= %ld\n", d);
        d &= -16;       Stdio.printf("i64 &= %ld\n", d);
        d ^= 255;       Stdio.printf("i64 ^= %ld\n", d);
    }

    void doubles(void)
    {
        e = 2.5d;
        e += 1.25d;     Stdio.printf("double += %ld\n", (i64)(e * 100.0d));
        e -= 0.5d;      Stdio.printf("double -= %ld\n", (i64)(e * 100.0d));
        e *= 4.0d;      Stdio.printf("double *= %ld\n", (i64)(e * 100.0d));
        e /= 8.0d;      Stdio.printf("double /= %ld\n", (i64)(e * 100.0d));
        e += 3;         Stdio.printf("double += int %ld\n", (i64)(e * 100.0d));
    }

    // Shift counts of three widths on the ivars.
    void shifts(u8 s8, u32 s32, u64 s64)
    {
        a = 3;  b = -3; c = 5; d = -5;
        a <<= s8;   b <<= s8;   c <<= s8;   d <<= s8;
        Stdio.printf("ivar << u8 %ld %ld %ld %ld\n", (i64)a, (i64)b, (i64)c, d);
        a <<= s32;  b <<= s32;  c <<= s32;  d <<= s32;
        Stdio.printf("ivar << u32 %ld %ld %ld %ld\n", (i64)a, (i64)b, (i64)c, d);
        c <<= s64;  d <<= s64;
        Stdio.printf("ivar << u64 %ld %ld\n", (i64)c, d);
        a = 200; b = -2000; c = 4000000000; d = -40000000000;
        a >>= s8;   b >>= s8;   c >>= s8;   d >>= s8;
        Stdio.printf("ivar >> u8 %ld %ld %ld %ld\n", (i64)a, (i64)b, (i64)c, d);
        a >>= s32;  b >>= s32;  c >>= s32;  d >>= s32;
        Stdio.printf("ivar >> u32 %ld %ld %ld %ld\n", (i64)a, (i64)b, (i64)c, d);
        c >>= s64;  d >>= s64;
        Stdio.printf("ivar >> u64 %ld %ld\n", (i64)c, d);
    }

    // A parameter and a local of an ivar's name take the update.
    void shadow(u32 c)
    {
        i16 b = 10;
        c += 5;
        c <<= 2;
        b *= 3;
        b -= 1;
        Stdio.printf("shadow param %ld local %ld\n", (i64)c, (i64)b);
    }

    void show(void)
    {
        Stdio.printf("fields %ld %ld %ld %ld %ld\n", (i64)a, (i64)b, (i64)c, d, (i64)(e * 100.0d));
    }
}

class SubAcc : Acc
{
    i32 own;

    // Inherited ivars and an ivar of its own, named bare in a subclass method.
    void mix(i32 k)
    {
        own = 7;
        own += k;
        own *= 3;
        own <<= 2;
        a = 9;
        a += k;
        a ^= $F0;
        d = 100;
        d -= k;
        d >>= 1;
        e = 1.5d;
        e *= 3.0d;
        Stdio.printf("sub %ld %ld %ld %ld\n", (i64)own, (i64)a, d, (i64)(e * 100.0d));
    }
}

void main(void)
{
    Acc* x = new Acc();
    x.bytes();
    x.shorts();
    x.words(400000000);
    x.longs(23);
    x.doubles();
    x.show();
    x.shifts(3, 5, 7);
    x.show();
    x.c = 77;
    x.b = 88;
    x.shadow(1);
    x.show();

    // The base class's methods through a subclass instance.
    SubAcc* y = new SubAcc();
    y.bytes();
    y.words(1);
    y.mix(4);
    y.shifts(1, 2, 3);
    y.show();

    // Locals and globals, with u8, u32 and u64 counts.
    u8 s8 = 3;
    u32 s32 = 5;
    u64 s64 = 9;
    u8 l8 = 7;
    i16 l16 = -7;
    u32 l32 = 11;
    i64 l64 = -11;
    l8 <<= s8;  l16 <<= s8;  l32 <<= s8;  l64 <<= s8;
    Stdio.printf("local << u8 %ld %ld %ld %ld\n", (i64)l8, (i64)l16, (i64)l32, l64);
    l8 <<= s32; l16 <<= s32; l32 <<= s32; l64 <<= s32;
    Stdio.printf("local << u32 %ld %ld %ld %ld\n", (i64)l8, (i64)l16, (i64)l32, l64);
    l32 <<= s64; l64 <<= s64;
    Stdio.printf("local << u64 %ld %ld\n", (i64)l32, l64);
    l8 = 250; l16 = -30000; l32 = 4000000000; l64 = -4000000000000;
    l8 >>= s8;  l16 >>= s8;  l32 >>= s8;  l64 >>= s8;
    Stdio.printf("local >> u8 %ld %ld %ld %ld\n", (i64)l8, (i64)l16, (i64)l32, l64);
    l8 >>= s32; l16 >>= s32; l32 >>= s32; l64 >>= s32;
    Stdio.printf("local >> u32 %ld %ld %ld %ld\n", (i64)l8, (i64)l16, (i64)l32, l64);
    l32 >>= s64; l64 >>= s64;
    Stdio.printf("local >> u64 %ld %ld\n", (i64)l32, l64);

    g8 = 5; g16 = -5; g32 = 13; g64 = -13;
    g8 <<= s8;  g16 <<= s8;  g32 <<= s8;  g64 <<= s8;
    Stdio.printf("global << u8 %ld %ld %ld %ld\n", (i64)g8, (i64)g16, (i64)g32, g64);
    g8 <<= s32; g16 <<= s32; g32 <<= s32; g64 <<= s32;
    Stdio.printf("global << u32 %ld %ld %ld %ld\n", (i64)g8, (i64)g16, (i64)g32, g64);
    g32 <<= s64; g64 <<= s64;
    Stdio.printf("global << u64 %ld %ld\n", (i64)g32, g64);
    g8 = 240; g16 = -20000; g32 = 3000000000; g64 = -3000000000000;
    g8 >>= s8;  g16 >>= s8;  g32 >>= s8;  g64 >>= s8;
    Stdio.printf("global >> u8 %ld %ld %ld %ld\n", (i64)g8, (i64)g16, (i64)g32, g64);
    g8 >>= s32; g16 >>= s32; g32 >>= s32; g64 >>= s32;
    Stdio.printf("global >> u32 %ld %ld %ld %ld\n", (i64)g8, (i64)g16, (i64)g32, g64);
    g32 >>= s64; g64 >>= s64;
    Stdio.printf("global >> u64 %ld %ld\n", (i64)g32, g64);
}
