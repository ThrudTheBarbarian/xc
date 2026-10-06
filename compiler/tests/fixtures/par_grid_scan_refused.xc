//xtc-flags: expect=sema-error
// A `par :grid` block's work items must not read each other's results either:
// the element left of this one is another item's.
#import "Par.xc"
u32 a[64];
i32 main(void)
    {
    par :grid(8, 8)
        {
        if (par.x > (u32)0)
            a[par.y * par.width + par.x] = a[par.y * par.width + par.x - (u32)1] + (u32)1;
        }
    return (i32)a[5];
    }
