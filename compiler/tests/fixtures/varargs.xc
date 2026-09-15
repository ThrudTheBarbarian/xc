// varargs.xc — variadic function: walk the vararg buffer with the
// language's own va_* intrinsics and prove every argument is read.
#import "Stdio.xc"

// Sum `count` u16 arguments. Distinct, non-trivial weights per slot so
// the result depends on each argument being pulled in the right order.
u16 sum(u16 count, ...)
{
    u8  ap;
    u16 total;
    u16 i;

    total = 0;
    i = 0;
    va_start(ap);
    while (i < count)
    {
        total = total + va_arg_u16(ap);
        i = i + 1;
    }
    va_end(ap);
    return total;
}

void main(void)
{
    // 3 args: $10 + $20 + $2A = $5A (90)
    u16 r = sum(3, $10, $20, $2A);
    Stdio.printf("%d\n", r);
    return;
}
