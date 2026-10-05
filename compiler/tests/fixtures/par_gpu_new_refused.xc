//xtc-flags: expect=sema-error
// A `par` body may not allocate: a GPU has no heap. (par-blocks.md §2)
#import "Par.xc"
class Cell : Object
    {
    i32 v;
    }
i32 main(void)
    {
    u32 a[16];
    par
        {
        for (u32 i in 0..16)
            {
            Cell* c = new Cell();
            a[i] = (u32)c.v;
            }
        }
    return (i32)a[3];
    }
