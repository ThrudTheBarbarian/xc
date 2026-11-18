// licm_cond_load.xc — a load under an `if` in a loop stays under it. The
// loop writes no memory, so LICM may move loads to the preheader, but this
// one is guarded by the null test: hoisted, it read p.x through null and the
// program crashed before printing anything.
#import "Stdio.xc"

class Box
    {
    i32 x;
    }

i32 sum(Box* p, i32 n)
    {
    i32 s = (i32)0;
    for (i32 i = (i32)0; i < n; i++)
        {
        if (p != (Box*)0)
            s = s + p.x;
        s = s + i;
        }
    return s;
    }

i32 main(void)
    {
    Box* b = new Box();
    b.x = (i32)3;
    Stdio.printf("%d\n", sum(b, (i32)10));
    Stdio.printf("%d\n", sum((Box*)0, (i32)10));
    return 0;
    }
