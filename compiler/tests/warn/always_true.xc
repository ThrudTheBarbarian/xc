//xtc-warn: always true
//xtc-warn: always false
// A literal condition, and a comparison of two literals. Both are things a
// reader sees as constant too — unlike a folded named constant, which is how
// a build switch is spelled and is deliberately NOT reported.
#import "Stdio.xc"
i32 main(void)
    {
    if ((i32)1)
        Stdio.printf("yes\n");
    while ((i32)2 > (i32)3)
        {
        Stdio.printf("no\n");
        }
    return 0;
    }
