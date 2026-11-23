//xtc-flags: expect=sema-error
// A range index operator takes both bounds.
// Refused: a range index on 'S' needs both bounds
#import <Stdio.xc>

class S
    {
    i32 items[4];
    i32 sum(i32 lo, i32 hi) :operator(self[lo..hi]) { return items[lo] + items[hi]; }
    }

i32 main(void)
    {
    S* s = new S();
    return s[..2];
    }
