//xtc-warn: never read
// A local assigned and then overwritten before anything reads it.
#import "Stdio.xc"
i32 main(void)
    {
    i32 x = (i32)1; // dead: overwritten below, never read
    x = (i32)2;
    Stdio.printf("%ld\n", x);
    return 0;
    }
