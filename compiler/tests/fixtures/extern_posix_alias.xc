//xtc-flags: target=arm64
// A program declaring POSIX names the Windows C runtime exports only with an
// underscore (bug 609). ucrtbase.dll has `_chdir` and `__isascii`, not `chdir`
// and `isascii`; mingw's import library binds the plain names to them. The
// win64 import map now carries that binding, so the program imports `_chdir`
// and loads: importing `chdir` itself failed before main with "entry point
// not found" on real Windows. Elsewhere these are the C library's own names.
#import "Stdio.xc"

i32 chdir(u8* path);
i32 isascii(i32 c);

i32 main(void)
{
    Stdio.printf("chdir to nowhere: %d\n", chdir("/no/such/directory/at/all"));
    Stdio.printf("isascii: %d %d\n", isascii((i32)65) != (i32)0 ? (i32)1 : (i32)0,
                 isascii((i32)200) != (i32)0 ? (i32)1 : (i32)0);
    return 0;
}
