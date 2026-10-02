// x86_op_named_symbols.xc — functions named like Intel-syntax operators.
//
// GNU as in Intel syntax reads `call eq` as the operator `eq`, not a symbol, and
// refuses the line; the x86-64 back end emitted these names bare, so any program
// with a function named eq, ne, lt, le, gt, ge, mod, shl, shr, and, or, xor, not
// or flat failed to assemble. They are now mangled like the register names, at
// the definition and at every call. Each body loops so the inliner leaves the
// call in place.

#import "Stdio.xc"
i32 eq(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 1;
    return s;
}
i32 ne(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 2;
    return s;
}
i32 lt(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 3;
    return s;
}
i32 le(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 4;
    return s;
}
i32 gt(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 5;
    return s;
}
i32 ge(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 6;
    return s;
}
i32 mod(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 7;
    return s;
}
i32 shl(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 8;
    return s;
}
i32 shr(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 9;
    return s;
}
i32 and(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 10;
    return s;
}
i32 or(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 11;
    return s;
}
i32 xor(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 12;
    return s;
}
i32 not(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 13;
    return s;
}
i32 flat(i32 k)
{
    i32 s = 0;
    for (i32 j = 0; j < k; j = j + 1)
        s = s + 14;
    return s;
}
i32 main(void)
{
    i32 t = 0;
    t = t + eq(3);
    t = t + ne(3);
    t = t + lt(3);
    t = t + le(3);
    t = t + gt(3);
    t = t + ge(3);
    t = t + mod(3);
    t = t + shl(3);
    t = t + shr(3);
    t = t + and(3);
    t = t + or(3);
    t = t + xor(3);
    t = t + not(3);
    t = t + flat(3);
    Stdio.printf("total=%d\n", t);
    return 0;
}
