//xtc-flags: target=xt6502, expect=sema-error
// undefined_function_refused.xc — a call to a function that is declared and
// never defined.
//
// On xt6502 the call assembled to `JSR $0000` with no diagnostic, so the
// program jumped to zero page and printed nothing. It is now an error that
// names the function and the call. The static linkers (m68k, x86_64, win64)
// already refused it. The xt6502 system has no C library, so a bodiless
// `printf` prototype is the usual way to hit this.
#import "Stdio.xc"

i32 printf(u8* fmt, ...);
i32 nowhere(i32 x);

i32 main(void)
{
    Stdio.printf("before\n");
    printf("never printed %d\n", nowhere(3));
    return 0;
}
