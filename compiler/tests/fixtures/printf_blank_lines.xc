// Empty lines are output too: two newlines in a row, a lone "\n", and a
// line of exactly 40 characters (the xt6502 screen's width) followed by
// its newline, which is not an empty line.
#import "Stdio.xc"

i32 main(void)
    {
    Stdio.printf("a\n\nb\n");
    Stdio.printf("\n");
    Stdio.printf("c\n");
    Stdio.printf("d\n\n\n");
    Stdio.printf("0123456789012345678901234567890123456789\n");
    Stdio.printf("e\n");
    Stdio.printf("0123456789012345678901234567890123456789\n\n");
    Stdio.printf("f\n");
    return 0;
    }
