//xtc-flags: expect=sema-error
// A `par` body may not do I/O: printf reaches code a GPU cannot run.
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    par
        {
        for (u32 i in 0..4)
            Stdio.printf("%u\n", i);
        }
    return 0;
    }
