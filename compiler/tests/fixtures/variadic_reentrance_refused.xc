//xtc-flags: target=xt6502, expect=sema-error
// A variadic that reads its own arguments must not reach another variadic.
//
// On xt6502, m68k, x86_64, win64 and wasm32 a variadic's arguments travel in
// ONE shared pack buffer, filled by the caller. `sumAll` runs va_start and
// reads that buffer while it loops; `report` calls Stdio.printf, which packs
// its own argument into the same buffer. With nothing refusing it the second
// argument read back as the first:
//
//     arg 111 / arg 111 / arg 333 / total 555     (want 222 and 666)
//
// The route goes through an ordinary function, so the check has to follow
// the calls transitively. arm64 and arm9 pass variadic arguments by the C ABI
// and accept this program (variadic_reentrance_native.xc).
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
        total = total + v;
    }
    va_end(ap);
    report("total", total);
}

i32 main(void)
{
    sumAll("arg", (u32)111, (u32)222, (u32)333);
    return 0;
}
