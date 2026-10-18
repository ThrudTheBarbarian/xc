//xtc-flags: target=arm64
// A parameter shadowed by an inner local of the same name, the inner one a
// class pointer the block assigns: the parameter is not a class pointer and
// must not be retained or released (the bool was, and the compiler built
// with it crashed at once, 2026-10-17).
#import "Stdio.xc"
class Box : Object
    {
    i32 v;
    }
Box* best(Box* a, Box* b)
    {
    return a.v >= b.v ? a : b;
    }
i32 pick(Box* a, Box* b, bool exact)
    {
    i32 r = 0;
    for (i32 k = 0; k < 3; k++)
        {
        if (k == 1)
            {
            Box* exact = best(a, b);
            if (exact.v < 0)
                exact = a;
            r = r + exact.v;
            }
        if (!exact)
            r = r + 100;
        }
    return r;
    }
i32 main(void)
    {
    Box* a = new Box();
    a.v = 7;
    Box* b = new Box();
    b.v = 9;
    Stdio.printf("%d %d\n", pick(a, b, false), pick(a, b, true));
    return 0;
    }
