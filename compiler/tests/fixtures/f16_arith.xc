// f16_arith.xc — arithmetic on the 16-bit floats. Each operation works in f32
// and rounds its result to the operands' type, so a chain of operations rounds
// after every step, where the same chain in f32 rounds to f32 only. Results
// print as bit patterns, checked against an independent model of that rule
// (numpy's float16 for f16; f32 results rounded to nearest even for bf16).
// Covers + - * /, negation, comparisons, compound assignment, ++ and --, a
// literal taking its operand's type, and mixed arithmetic widening to f32.
// f16_sqrt.xc has the square root.
#import "Stdio.xc"

u16 hb(f16 h) { return *(u16*)&h; }
u16 bb(bf16 g) { return *(u16*)&g; }

void putf(f32 f)
{
    u32 u = *(u32*)&f;
    Stdio.printf(" %x:%x\n", (u16)(u >> 16), (u16)u);
}

void basics(void)
{
    f16 a = 1.0;
    f16 b = 0.0004887;
    f16 s = a + b;
    f32 fs = (f32)a + (f32)b;
    Stdio.printf("add %x %x", hb(b), hb(s));
    putf(fs);

    f16 x = 3.14159;
    f16 y = 2.71828;
    Stdio.printf("ops %x %x %x %x\n", hb(x + y), hb(x - y), hb(x * y), hb(x / y));
    f16 chain = x * y + a / x - y;
    f32 fchain = (f32)x * (f32)y + (f32)a / (f32)x - (f32)y;
    Stdio.printf("chain %x", hb(chain));
    putf(fchain);
    Stdio.printf("neg %x %x\n", hb(-x), hb(-(x - x)));
}

void assigns(void)
{
    f16 x = 3.14159;
    f16 y = 2.71828;
    f16 a = 1.0;

    f16 tenth = 0.1;
    f16 acc = 0;
    f32 facc = 0;
    for (u32 i = 0; i < 100; i++)
    {
        acc = acc + tenth;
        facc = facc + (f32)tenth;
    }
    Stdio.printf("sum %x", hb(acc));
    putf(facc);

    f16 c = x;
    c += 1;
    Stdio.printf("comp %x", hb(c));
    c -= y;
    Stdio.printf(" %x", hb(c));
    c *= 3;
    Stdio.printf(" %x", hb(c));
    c /= 7;
    Stdio.printf(" %x\n", hb(c));
    f16 k = 2047;
    k++;
    Stdio.printf("step %x", hb(k));
    k++;
    Stdio.printf(" %x", hb(k));
    k--;
    Stdio.printf(" %x\n", hb(k));

    compares(x, y, a, k);
}

void compares(f16 x, f16 y, f16 a, f16 k)
{
    u32 cmp = 0;
    if (x > y) cmp = cmp | 1;
    if (y < x) cmp = cmp | 2;
    if (x == x) cmp = cmp | 4;
    if (x != y) cmp = cmp | 8;
    if (a >= 1.0) cmp = cmp | 16;
    if (a <= 0.5) cmp = cmp | 32;
    f16 nz = -0.0;
    if (nz == 0) cmp = cmp | 64;
    Stdio.printf("cmp %d\n", (i16)cmp);

    f32 mixed = x + 0.25d;
    f32 wide = x * (f32)1.5;
    Stdio.printf("mixed %f %x", mixed, hb(x * 0.5));
    putf(wide);

}

void brain(void)
{
    bf16 g = 1.0;
    bf16 d = 0.00390625;
    bf16 gs = g + d;
    bf16 p = 3.14159;
    bf16 q = 2.71828;
    Stdio.printf("bf16 %x %x %x %x\n", bb(gs), bb(p + q), bb(p * q), bb(p / q));
    bf16 bacc = 0;
    for (u32 i = 0; i < 100; i++)
        bacc += (bf16)0.1;
    Stdio.printf("bsum %x %x\n", bb(bacc), bb(-p));
    bf16 big = 1.0e38;
    Stdio.printf("bover %x %x\n", bb(big * 4), bb(big * -4));
    f16 hbig = 60000;
    Stdio.printf("hover %x %x\n", hb(hbig + hbig), hb(hbig * 0.0000001));
}

i32 main(void)
{
    basics();
    assigns();
    brain();
    return 0;
}
