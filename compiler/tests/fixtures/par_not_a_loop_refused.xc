//xtc-flags: expect=sema-error
// Phase 1 takes the loop form only: the body is one ascending `for (T i in a..b)`.
#import "Par.xc"
i32 main(void)
    {
    u32 a[16];
    par
        {
        a[0] = (u32)1;
        a[1] = (u32)2;
        }
    return (i32)a[0];
    }
