// f4_arith.xc — arithmetic in f4: every operation works in f32 from exact
// operands and rounds once to e2m1 (nearest even, saturating at ±6, NaN to
// +0), which is the correctly rounded result. All 256 pairs of patterns for
// + - * and /, each result a hex digit, against the exact-rational model;
// then comparisons, negation, compound assignment and ++/--.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 b4(f4 x)
{
    u8* p = (u8*)&x;
    return (u16)p[0];
}

f4 f4of(u16 b)
{
    u8 v = (u8)b;
    f4[] r = (f4[])&v;
    return r[0];
}

void add(void)
{
    Stdio.printf("+\n");
    for (u16 a = 0; a < 16; a++)
        {
        for (u16 b = 0; b < 16; b++)
            Stdio.printf("%x", b4(f4of(a) + f4of(b)));
        Stdio.printf("\n");
        }
}

void sub(void)
{
    Stdio.printf("-\n");
    for (u16 a = 0; a < 16; a++)
        {
        for (u16 b = 0; b < 16; b++)
            Stdio.printf("%x", b4(f4of(a) - f4of(b)));
        Stdio.printf("\n");
        }
}

void mul(void)
{
    Stdio.printf("*\n");
    for (u16 a = 0; a < 16; a++)
        {
        for (u16 b = 0; b < 16; b++)
            Stdio.printf("%x", b4(f4of(a) * f4of(b)));
        Stdio.printf("\n");
        }
}

void div(void)
{
    Stdio.printf("/\n");
    for (u16 a = 0; a < 16; a++)
        {
        for (u16 b = 0; b < 16; b++)
            Stdio.printf("%x", b4(f4of(a) / f4of(b)));
        Stdio.printf("\n");
        }
}

void compare(void)
{
    Stdio.printf("lt eq\n");
    for (u16 a = 0; a < 16; a++)
        {
        u16 lt = 0;
        u16 eq = 0;
        for (u16 b = 0; b < 16; b++)
            {
            if (f4of(a) < f4of(b))
                lt = lt | (u16)(1 << b);
            if (f4of(a) == f4of(b))
                eq = eq | (u16)(1 << b);
            }
        Stdio.printf("%x %x\n", lt, eq);
        }
}

void steps(void)
{
    f4 x = 1.5;
    x += 2.0;
    Stdio.printf("%x", b4(x));
    x -= 0.5;
    Stdio.printf(" %x", b4(x));
    x *= 3.0;
    Stdio.printf(" %x", b4(x));
    x /= 4.0;
    Stdio.printf(" %x", b4(x));
    x = -x;
    Stdio.printf(" %x", b4(x));
    x++;
    Stdio.printf(" %x", b4(x));
    x--;
    x--;
    Stdio.printf(" %x\n", b4(x));
}

i32 main(void)
{
    add();
    sub();
    mul();
    div();
    compare();
    steps();
    return 0;
}
