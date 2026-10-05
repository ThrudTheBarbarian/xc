//xtc-flags: expect=sema-error
// A `par` body may not recurse, even through a helper: a GPU has no general
// call stack for it.
#import "Par.xc"
u32 fib(u32 n)
    {
    return n < (u32)2 ? n : fib(n - (u32)1) + fib(n - (u32)2);
    }
i32 main(void)
    {
    u32 a[16];
    par
        {
        for (u32 i in 0..16)
            a[i] = fib(i);
        }
    return (i32)a[5];
    }
