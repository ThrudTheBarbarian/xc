//xtc-flags: expect=sema-error
// An index pattern has at least one index.
// Refused: an index operator needs an index, such as (self[i])
#import <Stdio.xc>

class V
    {
    i32 x;
    i32 first() :operator(self[]) { return x; }
    }

i32 main(void) { return 0; }
