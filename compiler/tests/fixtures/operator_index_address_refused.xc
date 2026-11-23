//xtc-flags: expect=sema-error
// An element read through an index operator is a call's result, with no
// address.
// Refused: '&' cannot take the address of an element read through an index operator
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    }

i32 main(void)
    {
    V* v = new V();
    i32* p = &v[0];
    return 0;
    }
