// `use` is contextual: `use Klass;` at the top level of a file is the
// directive, and `use` is an ordinary name everywhere else. The lexer made it
// a keyword, so a parameter called use was "Expected ')' but found 'use'".
#import "Stdio.xc"

class Tally
    {
    static u32 twice(u32 v) { return v * (u32)2; }
    }

use Tally;

u32 countSet(u8* use, u32 n)
    {
    u32 c = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        if (use[i] != (u8)0)
            c = c + (u32)1;
    return c;
    }

i32 main(void)
    {
    u8 flags[4];
    flags[0] = (u8)1;
    flags[1] = (u8)0;
    flags[2] = (u8)1;
    flags[3] = (u8)0;
    u32 use = countSet(&flags[0], (u32)4);
    Stdio.printf("%u %u\n", use, twice(use));
    return 0;
    }
