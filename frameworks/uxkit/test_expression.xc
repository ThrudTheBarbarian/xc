// test_expression.xc — UXExpression: precedence, parens, variables, comparisons.
#import <Stdio.xc>
#import "UXExpression.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
i32 evalc(u8* src, UXBindings* b)
    {
    return UXExpression.parse(src).evaluate(b);
    }

void main(void)
    {
    gFails = (i32)0;
    UXBindings* empty = new UXBindings();

    // precedence
    check("2 + 3 * 4", evalc((u8*)"2 + 3 * 4", empty), (i32)14);
    check("(2 + 3) * 4", evalc((u8*)"(2 + 3) * 4", empty), (i32)20);
    check("10 - 2 - 3 (left assoc)", evalc((u8*)"10 - 2 - 3", empty), (i32)5);
    check("20 / 2 / 5", evalc((u8*)"20 / 2 / 5", empty), (i32)2);
    check("10 % 3", evalc((u8*)"10 % 3", empty), (i32)1);
    check("nested parens", evalc((u8*)"((1 + 2) * (3 + 4))", empty), (i32)21);

    // unary minus
    check("unary minus", evalc((u8*)"-5 + 8", empty), (i32)3);
    check("minus times", evalc((u8*)"-3 * -3", empty), (i32)9);

    // variables
    UXBindings* b = new UXBindings();
    b.set((u8*)"qty", (i32)3);
    b.set((u8*)"price", (i32)200);
    b.set((u8*)"tax", (i32)50);
    check("qty * price + tax", evalc((u8*)"qty * price + tax", b), (i32)650);
    check("unbound var reads 0", evalc((u8*)"missing + 7", b), (i32)7);
    b.set((u8*)"qty", (i32)5); // rebinding
    check("rebinding updates", evalc((u8*)"qty * 2", b), (i32)10);

    // comparisons yield 1/0
    check("5 > 3", evalc((u8*)"5 > 3", empty), (i32)1);
    check("5 < 3", evalc((u8*)"5 < 3", empty), (i32)0);
    check("4 == 4", evalc((u8*)"4 == 4", empty), (i32)1);
    check("4 != 4", evalc((u8*)"4 != 4", empty), (i32)0);
    check("3 <= 3", evalc((u8*)"3 <= 3", empty), (i32)1);
    check("expr compare", evalc((u8*)"qty * 2 >= price", b), (i32)0); // 10 >= 200 -> 0
    check("compare with arithmetic both sides", evalc((u8*)"1 + 1 == 2", empty), (i32)1);

    // validity
    check("valid parse", UXExpression.parse((u8*)"1 + 2 * 3").isValid() ? (i32)1 : (i32)0, (i32)1);
    check("trailing junk is invalid", UXExpression.parse((u8*)"1 + 2 )").isValid() ? (i32)1 : (i32)0, (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXExpression — precedence, parens, unary, variables, comparisons.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
