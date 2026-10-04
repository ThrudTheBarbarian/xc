//xtc-flags: expect=sema-error
// A `par` body may not assign a captured scalar: every work item has its own
// copy, so the write would vanish. Make it a reduction or write to an array.
#import "Par.xc"
i32 main(void)
    {
    u32 a[16];
    u32 last = (u32)0;
    par
        {
        for (u32 i in 0..16)
            {
            a[i] = i;
            last = i;
            }
        }
    return (i32)last;
    }
