//xtc-flags: expect=sema-error
// `return` ends a `par :grid` work item, but inside a loop of the body's own it
// would only end that loop's iteration: refused, with a way round.
#import "Par.xc"
u32 a[64];
i32 main(void)
    {
    par :grid(8, 8)
        {
        for (u32 k in 0..8)
            {
            if (k == par.x)
                return;
            }
        a[par.y * par.width + par.x] = (u32)1;
        }
    return (i32)a[5];
    }
