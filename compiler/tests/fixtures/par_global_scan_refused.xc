//xtc-flags: expect=sema-error
// The independence rule covers global arrays too: g[i] reads the element the
// previous item writes.
#import "Par.xc"
u32 g[64];
i32 main(void)
    {
    par
        {
        for (u32 i in 1..64)
            g[i] = g[i - 1] + (u32)1;
        }
    return (i32)g[5];
    }
