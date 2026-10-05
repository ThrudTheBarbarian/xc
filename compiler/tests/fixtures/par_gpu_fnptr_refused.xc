//xtc-flags: expect=sema-error
// A `par` body may not call through a function pointer: a GPU kernel's calls
// are all known when it is built.
#import "Par.xc"
typedef u32 op_t(u32 x);
u32 twice(u32 x) { return x * (u32)2; }
op_t* chosen = &twice;
i32 main(void)
    {
    u32 a[16];
    par
        {
        for (u32 i in 0..16)
            a[i] = chosen(i);
        }
    return (i32)a[3];
    }
