//xtc-flags: expect=sema-error
// A `par` body may not write a global scalar (every work item would race on
// it). Reading one is fine, and so is writing a global ARRAY element by element.
#import "Par.xc"
u32 seen;
i32 main(void)
    {
    u32 a[16];
    par
        {
        for (u32 i in 0..16)
            {
            a[i] = i;
            seen = i;
            }
        }
    return (i32)a[3];
    }
