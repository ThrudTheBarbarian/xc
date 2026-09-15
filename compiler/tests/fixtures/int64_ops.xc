// int64_ops.xc — every 64-bit operation, on every target that implements them.
//
// Operands are chosen so a 32-bit implementation gives a different answer, and
// each one is routed through a non-constant helper so the optimiser cannot fold
// the operation away before the back end sees it. That matters: an earlier
// version of this test "passed" on xt6502 only because `5 * 3` had been folded
// and the multiply never reached the back end at all.
#import "Stdio.xc"

// Every 64-bit operation, with operands chosen so a 32-bit implementation
// gives a different answer. Printed as two 32-bit halves because %ld is the
// widest specifier. Values are computed through non-constant helpers so the
// optimiser cannot fold the operation away before the back end sees it.

i64 add(i64 a, i64 b) { return a + b; }
i64 sub(i64 a, i64 b) { return a - b; }
i64 mul(i64 a, i64 b) { return a * b; }
i64 dvi(i64 a, i64 b) { return a / b; }
i64 mod(i64 a, i64 b) { return a % b; }
u64 shl(u64 a, u8 n)  { return a << n; }
u64 shr(u64 a, u8 n)  { return a >> n; }
i64 sar(i64 a, u8 n)  { return a >> n; }

void show(string tag, u64 v)
{
    Stdio.printf("%s %ld:%ld\n", tag, (u32)(v >> (u64)32), (u32)v);
}

i32 main(void)
{
    u64 big = shl((u64)1, (u8)40);          // 2^40
    show("shl ", big);
    show("shr ", shr(big, (u8)8));           // 2^32
    show("add ", (u64)add((i64)big, (i64)5));
    show("sub ", (u64)sub((i64)big, (i64)5));
    show("mul ", (u64)mul((i64)1000000, (i64)1000000));
    show("div ", (u64)dvi((i64)mul((i64)1000000,(i64)1000000), (i64)1000000));
    show("mod ", (u64)mod((i64)add((i64)mul((i64)1000000,(i64)1000000),(i64)7), (i64)1000000));

    i64 neg = sub((i64)0, (i64)1000000);
    show("sar ", (u64)sar(neg, (u8)1));      // -500000, sign preserved
    show("ndiv", (u64)dvi(neg, (i64)7));     // -142857
    show("nmod", (u64)mod(neg, (i64)7));     // -1 (sign of dividend)
    return 0;
}
