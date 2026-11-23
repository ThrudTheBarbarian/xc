//xtc-flags: expect=sema-error
// An index-set pattern names the value it assigns.
// Refused: an index-set operator needs a value after '=', such as (self[i] = v)
#import <Stdio.xc>

class V
    {
    i32 items[4];
    void put(i32 i, i32 x) :operator(self[i] =) { items[i] = x; }
    }

i32 main(void) { return 0; }
