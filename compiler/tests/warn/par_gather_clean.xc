// A gather — reading through an index table — and writes at k*i + c are
// provably independent: no par-scatter warning (par-blocks.md §4).
#import "Par.xc"
void main(void)
    {
    u32 a[64];
    u32 b[128];
    u32 idx[64];
    par gather { for (u32 i in 0..64) { a[i] = b[idx[i]]; } }
    par pairs { for (u32 i in 0..64) { b[(u32)2 * i] = a[i]; b[(u32)2 * i + (u32)1] = a[i]; } }
    }
