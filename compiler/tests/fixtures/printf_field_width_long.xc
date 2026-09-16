//xtc-na: xt6502 — the 6502 Stdio consumes width without padding, to stay inside its frame budget
// printf_field_width_long.xc — field widths on the 32-bit and character
// conversions.
//
// Field widths reached `%d`, `%u` and `%s` but not `%ld`, `%lu` or `%c`, so
// `Stdio.printf("%8ld", (i32)123456)` printed the digits with no padding on
// every target except arm64. The width is parsed either way, which is why the
// output was short rather than wrong.
//
// A width smaller than the value never truncates, so the last line prints all
// six digits.
#import "Stdio.xc"

i32 main(void)
{
    Stdio.printf("[%8ld]\n",  (i32)123456);
    Stdio.printf("[%-8ld]\n", (i32)123456);
    Stdio.printf("[%08ld]\n", (i32)123456);
    Stdio.printf("[%10ld]\n", (i32)42);
    Stdio.printf("[%8lu]\n",  (u32)77);
    Stdio.printf("[%3c]\n",   (u8)'X');
    Stdio.printf("[%-3c]\n",  (u8)'X');
    Stdio.printf("[%2ld]\n",  (i32)123456);
    return 0;
}
