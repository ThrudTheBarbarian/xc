//xtc-flags: target=arm64
//xtc-na: x86_64,win64 — x86-64 passes variadic arguments through the shared buffer, so this is refused there (variadic_reentrance_refused.xc)
// A variadic that reads its arguments and calls another variadic while it
// does, on a target that passes variadic arguments by the C ABI.
//
// arm64 and arm9 have no shared pack buffer, so nothing can be overwritten
// and the program is valid. It used to be refused there by the check that
// guards the buffer on the other targets (variadic_reentrance_refused.xc).
#import "Foundation.xc"
#import "Stdio.xc"

void report(string tag, u32 v)
{
    Stdio.printf("%s %lu\n", tag, v);
}

void sumAll(string tag, ...)
{
    u8 ap;
    va_start(ap);
    u32 total = 0;
    for (u32 i = 0; i < 3; i++)
    {
        u32 v = va_arg_u32(ap);
        report(tag, v);
        Stdio.printf("  seen %lu\n", i + 1);
        total = total + v;
    }
    va_end(ap);
    report("total", total);
}

// Recursion through the variadic itself is fine too: each call has its own
// argument area.
u32 depth(u32 n, ...)
{
    u8 ap;
    va_start(ap);
    u32 extra = va_arg_u32(ap);
    va_end(ap);
    if (n == 0)
        return extra;
    return extra + depth(n - 1, extra + 1);
}

i32 main(void)
{
    sumAll("arg", (u32)111, (u32)222, (u32)333);
    Stdio.printf("depth %lu\n", depth(3, (u32)10));
    return 0;
}
