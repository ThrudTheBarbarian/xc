//xtc-na: xt6502, m68k — prints 32- and 64-bit values through %ld
// A compound assignment whose left side is an array or pointer element
// (`a[i] op= x`, `@p op= x`): every operator, on a global array, a local array
// and a pointer, at several element widths and signedness, and with indices
// that have side effects. The address is formed once, so `a[at(i)] += 1`
// calls at() once; `calls` would double if the index were evaluated twice.
#use Stdio

u8 g8[4];
i16 g16[4];
i64 g64[4];
double gd[4];
u32 calls;
u32 cursor;

// Returns its argument and counts the call.
u32 at(u32 i)
{
    calls = calls + 1;
    return i;
}

// Moves the cursor on and returns its new position.
u32 bump(void)
{
    cursor = cursor + 1;
    return cursor;
}

void main(void)
{
    // u8, global array: computed at u8, so it wraps.
    g8[1] = 250;
    g8[1] += 10;    Stdio.printf("u8 += %ld\n", (i64)g8[1]);
    g8[1] -= 5;     Stdio.printf("u8 -= %ld\n", (i64)g8[1]);
    g8[1] *= 3;     Stdio.printf("u8 *= %ld\n", (i64)g8[1]);
    g8[1] /= 7;     Stdio.printf("u8 /= %ld\n", (i64)g8[1]);
    g8[1] %= 5;     Stdio.printf("u8 %%= %ld\n", (i64)g8[1]);
    g8[1] |= $F0;   Stdio.printf("u8 |= %ld\n", (i64)g8[1]);
    g8[1] &= $3C;   Stdio.printf("u8 &= %ld\n", (i64)g8[1]);
    g8[1] ^= $FF;   Stdio.printf("u8 ^= %ld\n", (i64)g8[1]);
    g8[1] <<= 2;    Stdio.printf("u8 <<= %ld\n", (i64)g8[1]);
    g8[1] >>= 3;    Stdio.printf("u8 >>= %ld\n", (i64)g8[1]);

    // i16, global array, through an index with a side effect.
    calls = 0;
    g16[2] = -1000;
    g16[at(2)] += 300;      Stdio.printf("i16 += %ld\n", (i64)g16[2]);
    g16[at(2)] -= 32000;    Stdio.printf("i16 -= %ld\n", (i64)g16[2]);
    g16[at(2)] -= 100;      Stdio.printf("i16 -= %ld\n", (i64)g16[2]);
    g16[at(2)] *= 2;        Stdio.printf("i16 *= %ld\n", (i64)g16[2]);
    g16[at(2)] /= 5;        Stdio.printf("i16 /= %ld\n", (i64)g16[2]);
    g16[at(2)] %= 5;        Stdio.printf("i16 %%= %ld\n", (i64)g16[2]);
    g16[at(2)] &= $0FF0;    Stdio.printf("i16 &= %ld\n", (i64)g16[2]);
    g16[at(2)] ^= $00FF;    Stdio.printf("i16 ^= %ld\n", (i64)g16[2]);
    g16[at(2)] <<= 4;       Stdio.printf("i16 <<= %ld\n", (i64)g16[2]);
    g16[at(2)] >>= 2;       Stdio.printf("i16 >>= %ld\n", (i64)g16[2]);
    g16[at(2)] |= 3;        Stdio.printf("i16 |= %ld\n", (i64)g16[2]);
    Stdio.printf("i16 calls %ld\n", (i64)calls);

    // u32, local array.
    u32 l32[4];
    l32[0] = 0; l32[1] = 0; l32[2] = 0;
    l32[3] = 4000000000;
    l32[3] += 500000000;    Stdio.printf("u32 += %ld\n", (i64)l32[3]);
    l32[3] -= 205032705;    Stdio.printf("u32 -= %ld\n", (i64)l32[3]);
    l32[3] *= 3;            Stdio.printf("u32 *= %ld\n", (i64)l32[3]);
    l32[3] /= 10;           Stdio.printf("u32 /= %ld\n", (i64)l32[3]);
    l32[3] %= 1000;         Stdio.printf("u32 %%= %ld\n", (i64)l32[3]);
    l32[3] |= $10000;       Stdio.printf("u32 |= %ld\n", (i64)l32[3]);
    l32[3] &= $1F0F0;       Stdio.printf("u32 &= %ld\n", (i64)l32[3]);
    l32[3] ^= $FFFFFFFF;    Stdio.printf("u32 ^= %ld\n", (i64)l32[3]);
    l32[3] >>= 20;          Stdio.printf("u32 >>= %ld\n", (i64)l32[3]);
    l32[3] <<= 24;          Stdio.printf("u32 <<= %ld\n", (i64)l32[3]);

    // i64, through a pointer into a global array, with a variable shift count.
    i64* p = &g64[0];
    u32 sh = 33;
    p[1] = -7;
    p[1] *= 1000000007;     Stdio.printf("i64 *= %ld\n", p[1]);
    p[1] += 3;              Stdio.printf("i64 += %ld\n", p[1]);
    p[1] -= 9000000000;     Stdio.printf("i64 -= %ld\n", p[1]);
    p[1] /= 4;              Stdio.printf("i64 /= %ld\n", p[1]);
    p[1] %= 1000000;        Stdio.printf("i64 %%= %ld\n", p[1]);
    p[1] <<= sh;            Stdio.printf("i64 <<= %ld\n", p[1]);
    p[1] >>= 30;            Stdio.printf("i64 >>= %ld\n", p[1]);
    p[1] |= 1;              Stdio.printf("i64 |= %ld\n", p[1]);
    p[1] &= -16;            Stdio.printf("i64 &= %ld\n", p[1]);
    p[1] ^= 255;            Stdio.printf("i64 ^= %ld\n", p[1]);
    Stdio.printf("i64 g64[1] %ld\n", g64[1]);

    // u8 through a heap pointer: wraps at the element width.
    u8* h = new u8[4];
    h[2] = 200;
    h[2] += 100;            Stdio.printf("heap u8 += %ld\n", (i64)h[2]);
    h[2] -= 50;             Stdio.printf("heap u8 -= %ld\n", (i64)h[2]);

    // double, global array, the arithmetic operators.
    gd[3] = 2.5d;
    gd[3] += 1.25d;         Stdio.printf("double += %ld\n", (i64)(gd[3] * 100.0d));
    gd[3] -= 0.5d;          Stdio.printf("double -= %ld\n", (i64)(gd[3] * 100.0d));
    gd[3] *= 4.0d;          Stdio.printf("double *= %ld\n", (i64)(gd[3] * 100.0d));
    gd[3] /= 8.0d;          Stdio.printf("double /= %ld\n", (i64)(gd[3] * 100.0d));

    // Side-effecting indices: each compound assignment calls at()/bump() once.
    calls = 0;
    l32[at(0)] += 1;
    l32[at(0)] += 1;
    l32[at(0)] *= 5;
    Stdio.printf("l32[0] %ld calls %ld\n", (i64)l32[0], (i64)calls);
    cursor = 0;
    g8[0] = 0; g8[1] = 0; g8[2] = 0; g8[3] = 0;
    g8[bump()] += 10;
    g8[bump()] += 20;
    g8[bump()] |= 7;
    Stdio.printf("g8 %ld %ld %ld %ld cursor %ld\n", (i64)g8[0], (i64)g8[1], (i64)g8[2], (i64)g8[3], (i64)cursor);

    // A nested element as the index, and a dereference.
    u8 idx[3];
    idx[0] = 2; idx[1] = 0; idx[2] = 2;
    calls = 0;
    l32[idx[at(1)]] += 40;
    l32[idx[at(2)]] -= 1;
    Stdio.printf("nested %ld %ld calls %ld\n", (i64)l32[0], (i64)l32[2], (i64)calls);
    i64* q = &g64[2];
    g64[2] = 6;
    *q += 4;
    *q *= 3;
    *q <<= 2;
    Stdio.printf("deref %ld\n", g64[2]);
}
