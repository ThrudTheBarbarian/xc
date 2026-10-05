//xtc-flags: expect=sema-error
// A `par` body may not capture a class instance (or a String, Array, Map or
// block): those are ARC'd heap objects, which a GPU cannot reach.
#import "Par.xc"
class Scale : Object
    {
    u32 k;
    u32 of(u32 x) { return x * k; }
    }
i32 main(void)
    {
    u32 a[16];
    Scale* s = new Scale();
    par
        {
        for (u32 i in 0..16)
            a[i] = s.of(i);
        }
    return (i32)a[3];
    }
