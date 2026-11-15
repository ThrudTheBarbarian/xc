// pp-diff parity: a block comment holding non-ASCII text. The two
// preprocessors blank a comment with one space per UTF-8 byte, so the columns
// after it (the code on its closing line) agree.
#import "Stdio.xc"
/* été — 😀
   still a comment — */ i32 answer(void) { return 42; }
i32 main(void)
    {
    Stdio.printf("%d\n", answer());
    return 0;
    }
