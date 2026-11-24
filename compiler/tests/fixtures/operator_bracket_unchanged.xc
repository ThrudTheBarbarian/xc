// `|` and `||` in a unit where no class defines a bracket operator: bitwise
// or and logical or as always, `|` after `||` included. Its assembly does
// not change.
#import <Stdio.xc>

i32 pick(i32 a, i32 b, bool p, bool q)
    {
    i32 r = a | b;
    if (p || q)
        r = r | 1;
    if (!p || !q || a == 0)
        r = r | 64;
    return r;
    }

i32 main(void)
    {
    Stdio.printf("%d %d\n", pick(4, 8, false, true), pick(0, 2, true, true));
    return 0;
    }
