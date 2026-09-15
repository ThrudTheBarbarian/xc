#use Stdio

// bug 210: tuple unpacking into NEW variables, and more than two return
// values. Two separate defects, both port-only, both found by a documentation
// example rather than by any gate:
//
//   parseTupleAssign parsed every target as an EXPRESSION, so `(a, b) = f()`
//   worked and `(u16 a, u16 b) = f()` failed at the first typed target with
//   "Expected ')' but found 'a'".
//
//   splitReturns passed the comma's INDEX to substringBytes(from, LEN), so
//   every part after the first ran too long. It clamps at end-of-string, which
//   is why TWO returns worked by luck and three did not: `u16,u16,bool` split
//   as "u16", "u16,boo", "bool" — hence `unsupported: type u16,boo`.
//
// So this fixture must use THREE or more returns AND typed targets; two
// untyped ones pass on the broken compiler.
u16, u16 two(void)              { return (u16)1, (u16)2; }
u16, u16, bool three(void)      { return (u16)3, (u16)4, true; }
u16, u16, u16, bool four(void)  { return (u16)5, (u16)6, (u16)7, false; }

i32 main()
{
    u16 x; u16 y;
    (x, y) = two();                              // bare targets
    printf("%d %d\n", x, y);

    (u16 a, u16 b, bool c) = three();            // all newly declared
    printf("%d %d %d\n", a, b, (i16)(c ? 1 : 0));

    u16 p;
    (p, u16 q, u16 r, bool s) = four();          // mixed existing and new
    printf("%d %d %d %d\n", p, q, r, (i16)(s ? 1 : 0));
    return 0;
}
