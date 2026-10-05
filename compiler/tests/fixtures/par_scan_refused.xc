//xtc-flags: expect=sema-error
// A `par` block's items must not read each other's results: b[i - 1] is
// written by another item, so this is a scan (a prefix sum), not a par.
// (par-blocks.md §4)
#import "Par.xc"
i32 main(void)
    {
    u32 a[64];
    u32 b[64];
    par
        {
        for (u32 i in 1..64)
            b[i] = a[i] + b[i - 1];
        }
    return (i32)b[5];
    }
