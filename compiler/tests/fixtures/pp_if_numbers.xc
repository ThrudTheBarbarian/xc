// pp_if_numbers.xc — numbers in #if keep their letters (#279). The #if
// evaluator replaces names it does not know with 0, and its scan used to
// start a name at any letter, including one inside a number: 0x10 read as
// 00, 10UL as 100, $FF as $0. And it works in 64 bits.
#import "Stdio.xc"

#define X 16

i32 main(void)
{
#if X == 0x10
    Stdio.printf("hex ok\n");
#else
    Stdio.printf("hex wrong\n");
#endif
#if 0x10 == 0
    Stdio.printf("hex zero wrong\n");
#else
    Stdio.printf("hex nonzero ok\n");
#endif
#if 10UL == 10 && 0x10u == 16 && 7L == 7
    Stdio.printf("suffix ok\n");
#else
    Stdio.printf("suffix wrong\n");
#endif
#if $FF == 255
    Stdio.printf("dollar ok\n");
#else
    Stdio.printf("dollar wrong\n");
#endif
#if 4294967296 > 4294967295 && (1 << 40) > 0
    Stdio.printf("wide ok\n");
#else
    Stdio.printf("wide wrong\n");
#endif
#if UNDEFINED_NAME == 0 && X1 == 0
    Stdio.printf("names ok\n");
#else
    Stdio.printf("names wrong\n");
#endif
    return 0;
}
