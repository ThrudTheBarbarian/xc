//xtc-flags: expect=sema-error
// A `par` block needs its runtime, Par.xc; the error says so.
i32 main(void)
    {
    u32 a[16];
    par
        {
        for (u32 i in 0..16)
            a[i] = i;
        }
    return (i32)a[3];
    }
