//xtc-warn: at an index computed from data
//xtc-warn: from every work item
// A `par` block that writes a buffer at an index the compiler cannot express
// as k*i + c (a scatter through an index table), or at one fixed element from
// every item, may have two items write the same element. Legal, unprovable:
// a warning (par-blocks.md §4), suppressed with -Wno-par-scatter.
#import "Par.xc"
void main(void)
    {
    u32 a[64];
    u32 b[64];
    u32 idx[64];
    par hist { for (u32 i in 0..64) { b[idx[i]] = a[i]; } }
    par last { for (u32 i in 0..64) { a[3] = b[i]; } }
    }
